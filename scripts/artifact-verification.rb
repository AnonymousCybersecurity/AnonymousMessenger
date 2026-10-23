# Shared verification of the actual Android files, not just their filenames or metadata.
module MessengerRelease
  BUNDLETOOL_VERSION = '1.18.3'
  BUNDLETOOL_SHA256 = 'a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29'
  # Verified from the existing v26.10.09-5 website APK, independently of Play signing.
  WEBSITE_CERT_SHA256 = '6b094a3d5f98b7d1bcf36a8aa41805b0c84b058582aee689bd2708cc211351a4'
  WEBSITE_APK = 'app-prod-website-release-signed.apk'

  def self.setup_bundletool(env = ENV, run: method(:execute))
    path = File.join(env.fetch('RUNNER_TEMP'), "bundletool-all-#{BUNDLETOOL_VERSION}.jar")
    unless File.file?(path)
      run.call(['gh', 'release', 'download', BUNDLETOOL_VERSION, '--repo', 'google/bundletool',
                '--pattern', File.basename(path), '--dir', env.fetch('RUNNER_TEMP')], capture: true, timeout: 180)
    end
    raise ArgumentError, 'Official bundletool checksum mismatch.' unless sha256_file(path) == BUNDLETOOL_SHA256

    File.open(env.fetch('GITHUB_ENV'), 'a:UTF-8') { |file| file.puts "BUNDLETOOL_JAR=#{path}" }
  end

  def self.verify_bundle(path, info, env: ENV, root: ROOT, run: method(:execute))
    pin = fingerprint(env.fetch('PLAY_UPLOAD_CERT_SHA256', ''))
    tool = env.fetch('BUNDLETOOL_JAR')
    raise ArgumentError, 'Official bundletool checksum mismatch.' unless sha256_file(tool) == BUNDLETOOL_SHA256

    run.call(['java', File.join(root, 'scripts/VerifyBundle.java'), path, pin], capture: true, timeout: 120)
    run.call(['java', '-jar', tool, 'validate', "--bundle=#{path}"], capture: true, timeout: 120)
    xml = run.call(['java', '-jar', tool, 'dump', 'manifest', "--bundle=#{path}", '--module=base'], capture: true, timeout: 120)
    manifest = REXML::Document.new(xml).root
    unless manifest&.name == 'manifest' && manifest.attributes['package'] == PACKAGE_NAME &&
           manifest.attributes['android:versionName'] == info.fetch('name') &&
           manifest.attributes['android:versionCode'] == info.fetch('code').to_s &&
           !manifest.attributes['split'] && manifest.elements['application'] &&
           !%w[true 1].include?(manifest.elements['application'].attributes['android:debuggable'])
      raise ArgumentError, 'Actual AAB package/version is wrong, split or debuggable.'
    end
    true
  rescue CommandError, REXML::ParseException
    raise ArgumentError, 'AAB validation, signature or manifest verification failed.'
  end

  def self.verify_apk(apk, info, certificate:, env: ENV, run: method(:execute))
    expected = fingerprint(certificate)
    tools = File.join(env['ANDROID_HOME'] || env.fetch('ANDROID_SDK_ROOT'), 'build-tools/36.0.0')
    cert = run.call(['java', '-jar', File.join(tools, 'lib/apksigner.jar'), 'verify', '--print-certs', apk], capture: true, timeout: 90)
    signers = cert.scan(/^Signer #\d+ certificate SHA-256 digest:\s*([a-fA-F0-9:]+)\s*$/).flatten
    unless signers.one? && fingerprint(signers.first) == expected
      raise ArgumentError, 'Actual APK signing certificate does not match the selected distribution key.'
    end
    manifest = run.call([File.join(tools, windows? ? 'aapt2.exe' : 'aapt2'), 'dump', 'badging', apk], capture: true, timeout: 90)
    attrs = manifest[/^package: (.+)$/, 1].to_s.scan(/(\w+)='([^']*)'/).to_h
    unless attrs['name'] == PACKAGE_NAME && attrs['versionName'] == info.fetch('name') &&
           attrs['versionCode'] == info.fetch('code').to_s && !attrs.key?('split') && !manifest.match?(/^application-debuggable\b/)
      raise ArgumentError, 'Actual APK package/version is wrong, split, or debuggable.'
    end
    raise ArgumentError, 'Downloaded APK is empty.' unless File.size?(apk)

    true
  rescue CommandError, SystemCallError
    raise ArgumentError, 'Actual APK signature/manifest verification failed.'
  end

  def self.attach_asset(api, release_id, path, filename = File.basename(path))
    size = File.size(path)
    digest = "sha256:#{sha256_file(path)}"
    check = lambda do |asset|
      unless { 'name' => filename, 'state' => 'uploaded', 'size' => size, 'digest' => digest }.all? { |key, value| asset[key] == value }
        raise ArgumentError, 'Conflicting or incomplete asset; existing assets are never overwritten.'
      end
      asset
    end
    1.upto(10) do |page|
      assets = api.request('GET', "/releases/#{positive(release_id, 'release ID')}/assets?per_page=100&page=#{page}")
      existing = assets.select { |asset| asset['name'] == filename }
      unless existing.empty?
        raise ArgumentError, 'Duplicate release assets.' unless existing.one?

        return check.call(existing.first)
      end
      break if assets.length < 100
      raise ArgumentError, 'Too many release assets to verify safely.' if page == 10
    end
    File.open(path, 'rb') do |file|
      check.call(api.request('POST', "https://uploads.github.com/repos/#{REPOSITORY}/releases/#{release_id}/assets?name=#{URI.encode_www_form_component(filename)}", file, upload: true))
    end
  end

  def self.prepare_website(env = ENV, root: ROOT, run: method(:execute))
    inputs = env.to_h.merge('PLAY_UPLOAD_KEYSTORE_BASE64' => env.fetch('KEYSTORE_B64', ''),
      'PLAY_UPLOAD_KEYSTORE_PASSWORD' => env.fetch('KEYSTORE_PASSWORD', ''), 'PLAY_UPLOAD_KEY_ALIAS' => env.fetch('KEY_ALIAS', ''),
      'PLAY_UPLOAD_KEY_PASSWORD' => env.fetch('KEY_PASSWORD', ''), 'PLAY_UPLOAD_CERT_SHA256' => WEBSITE_CERT_SHA256)
    prepare_ci(inputs, root: root, run: run)
  end

  def self.publish_website(api, env = ENV, root: ROOT, run: method(:execute))
    context(env)
    info = release_info('github', root)
    release = resolve_apk(api, info, env)
    apk = File.join(root, WEBSITE_APK)
    verify_apk(apk, info, certificate: WEBSITE_CERT_SHA256, env: env, run: run)
    metadata = { 'apps' => [{ 'packageName' => PACKAGE_NAME, 'suggestedVersionCode' => info.fetch('code') }],
      'packages' => { PACKAGE_NAME => [{ 'versionName' => info.fetch('name'), 'versionCode' => info.fetch('code'),
                                        'apkName' => WEBSITE_APK, 'hash' => sha256_file(apk) }] } }
    index = File.join(root, 'index-v1.json')
    write_json(index, metadata)
    attach_asset(api, release.fetch('release_id'), apk)
    attach_asset(api, release.fetch('release_id'), index)
    # Installed website clients still use /releases/latest/download. Move latest only
    # once both verified updater assets exist; Play-only pages must not hide them.
    api.request('PATCH', "/releases/#{release.fetch('release_id')}", { 'make_latest' => 'true' })
    puts 'Verified website APK and updater index attached; Play APKs never replace these assets.'
  end
end
