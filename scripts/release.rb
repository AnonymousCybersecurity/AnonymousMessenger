# AnonymousMessenger release commands, commit markers and shared Fastlane helpers.
require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'optparse'
require 'rbconfig'
require 'rexml/document'
require 'tmpdir'
require 'uri'
require_relative 'artifact-verification'

module MessengerRelease
  ROOT = File.expand_path('..', __dir__)
  REPOSITORY = 'AnonymousCybersecurity/AnonymousMessenger'
  REPOSITORY_ID = '1198767196'
  PACKAGE_NAME = 'it.aitechnology.anonymous'
  BRANCH = 'main'
  WORKFLOW = '.github/workflows/android-play.yml'
  AAB = 'app/build/outputs/bundle/prodStoreRelease/app-prod-store-release.aab'
  AAB_PATH = File.join(ROOT, AAB)
  MAX_CODE = 2_100_000_000

  class CommandError < StandardError; end

  def self.windows?
    RbConfig::CONFIG.fetch('host_os').match?(/mswin|mingw/)
  end

  def self.read_text(path)
    text = File.read(path, encoding: 'bom|utf-8').gsub(/\r\n?/, "\n")
    raise ArgumentError, "Invalid UTF-8 text: #{path}" unless text.valid_encoding?

    text
  end

  def self.sha256_file(path)
    Digest::SHA256.file(path).hexdigest
  end

  def self.version_info(root = ROOT)
    text = read_text(File.join(root, 'app/build.gradle.kts'))
    literal = lambda do |pattern|
      values = text.scan(pattern).flatten
      unless values.length == 1
        raise ArgumentError, 'Expected one literal Messenger canonical version, revision and hotfix declaration.'
      end
      values.first
    end
    canonical_name = literal.call(/^val canonicalVersionName = "([^"]+)"(?:\s*\/\/.*)?$/)
    canonical_code = literal.call(/^val canonicalVersionCode = (\d+)(?:\s*\/\/.*)?$/).to_i
    revision = literal.call(/^val anonymousRevision = (\d+)\s*$/).to_i
    hotfix = literal.call(/^val currentHotfixVersion = (\d+)\s*$/).to_i
    maximum = literal.call(/^val maxHotfixVersions = (\d+)\s*$/).to_i
    properties = read_text(File.join(root, 'app/gradle.properties'))
    packages = properties.scan(/^basePackageId\s*=\s*(\S+)\s*$/).flatten
    package = packages.one? ? packages.first : nil
    name = "#{canonical_name}-#{revision}"
    code = canonical_code * maximum + revision + hotfix
    unless package == PACKAGE_NAME && canonical_name.match?(/\A\d{2}\.\d{2}\.\d{2}\z/) &&
           canonical_code.positive? && maximum == 100 && revision + hotfix < maximum && code.between?(1, MAX_CODE)
      raise ArgumentError, 'Invalid Messenger package/version in app/build.gradle.kts.'
    end

    { 'package' => package, 'name' => name, 'code' => code }
  end

  def self.read_notes(path, limit = nil)
    raise ArgumentError, "Missing release notes: #{path}" unless File.file?(path)

    text = read_text(path).gsub(/\A[[:space:]]+|[[:space:]]+\z/, '')
    content = text.gsub(/<!--.*?-->/m, '').lines.reject { |line| line.match?(/^\s*(?:#|\/\/|;)/) }.join.strip
    if content.empty? || text.match?(/\b(RELEASE_NOTES_TODO|TODO|TBD|PLACEHOLDER)\b/i)
      raise ArgumentError, "Complete and review release notes before publishing: #{path}"
    end
    if limit && text.length > limit
      raise ArgumentError, "Play notes exceed #{limit} Unicode characters: #{path}"
    end
    if limit && text.match?(/<[^>]+>|^\s*(?:[#]{1,6}\s|[-*]\s|```)|\[[^\]]+\]\([^\)]+\)/)
      raise ArgumentError, "Play notes must be plain text: #{path}"
    end

    text
  end

  def self.play_notes(code, root = ROOT)
    raise ArgumentError, 'Invalid notes versionCode.' unless code.is_a?(Integer) && code.between?(1, MAX_CODE)

    directory = File.join(root, 'fastlane/metadata/android')
    result = { 'en-US' => read_notes(File.join(directory, "en-US/changelogs/#{code}.txt"), 500) }
    Dir.glob(File.join(directory, "*/changelogs/#{code}.txt")).sort.each do |path|
      locale = File.basename(File.dirname(File.dirname(path)))
      raise ArgumentError, "Invalid Play locale: #{locale}" unless locale.match?(/\A[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z/)

      result[locale] = read_notes(path, 500)
    end
    result
  end

  def self.release_info(destination, root = ROOT)
    raise ArgumentError, 'Destination must be github, play, or both.' unless %w[github play both].include?(destination)

    info = version_info(root)
    info['github_notes'] = read_notes(File.join(root, "release-notes/#{info.fetch('name')}.md")) unless destination == 'play'
    info['play_notes'] = play_notes(info.fetch('code'), root) unless destination == 'github'
    info
  end

  def self.context(env = ENV)
    unless env['GITHUB_REPOSITORY'] == REPOSITORY && env['GITHUB_REPOSITORY_ID'] == REPOSITORY_ID &&
           env['GITHUB_REF'] == "refs/heads/#{BRANCH}" && %w[workflow_dispatch push].include?(env['GITHUB_EVENT_NAME']) &&
           env.fetch('GITHUB_SHA', '').match?(/\A[a-f0-9]{40}\z/)
      raise ArgumentError, "Run this workflow from #{REPOSITORY} on #{BRANCH}, by push or manual dispatch."
    end
    push_event(env) if env['GITHUB_EVENT_NAME'] == 'push'
  end

  def self.push_event(env)
    event = JSON.parse(read_text(env.fetch('GITHUB_EVENT_PATH', '')))
    unless event['deleted'] == false && event['ref'] == "refs/heads/#{BRANCH}" &&
           event['after'] == env['GITHUB_SHA'] && event.dig('head_commit', 'id') == env['GITHUB_SHA'] &&
           event.dig('head_commit', 'message').is_a?(String) &&
           event.dig('repository', 'id').to_s == REPOSITORY_ID && event.dig('repository', 'full_name') == REPOSITORY
      raise ArgumentError, 'Publishing requires a main push with a matching repository and tip commit.'
    end
    event
  rescue JSON::ParserError, SystemCallError, TypeError
    raise ArgumentError, 'Cannot read a valid GitHub push event.'
  end

  def self.push_options(env)
    event = push_event(env)
    messages = [event.fetch('head_commit')] + event.fetch('commits', [])
    if messages.any? { |commit| commit.fetch('message', '').match?(/\[(?:skip ci|ci skip|no ci|skip actions|actions skip)\]|^skip-checks:\s*true\s*$/i) }
      return { 'action' => 'skip', 'destination' => 'github', 'track' => 'internal' }
    end

    # Read data from the event file, never interpolate a commit message into shell code.
    message = event.fetch('head_commit').fetch('message')
    markers = message.scan(/\[publish:([^\]\r\n]*)\]/i).flatten.map(&:downcase)
    if markers.length > 1 || message.scan(/\[publish\b/i).length != markers.length ||
       markers.any? { |marker| !%w[github play play:testtrack both both:testtrack].include?(marker) }
      raise ArgumentError, 'Use one marker: [publish:github], [publish:play[:testtrack]], or [publish:both[:testtrack]].'
    end
    destination, modifier = markers.fetch(0, 'github').split(':')
    { 'action' => 'release', 'destination' => destination, 'track' => modifier == 'testtrack' ? 'internal' : 'production' }
  end

  def self.positive(value, label, maximum = nil)
    unless value.to_s.match?(/\A[1-9][0-9]*\z/) && (!maximum || value.to_i <= maximum)
      raise ArgumentError, "#{label} must be a positive integer#{maximum ? " up to #{maximum}." : '.'}"
    end
    value.to_s
  end

  def self.release_plan(env = ENV)
    context(env)
    pushed = env['GITHUB_EVENT_NAME'] == 'push'
    options = pushed ? push_options(env) : { 'action' => env['RELEASE_ACTION'],
      'destination' => env.fetch('RELEASE_DESTINATION', 'both'), 'track' => env.fetch('PLAY_TRACK', 'internal') }
    action = options.fetch('action')
    destination = options.fetch('destination')
    unless %w[verify build release internal promote].include?(action) || (pushed && action == 'skip')
      raise ArgumentError, 'Unknown release action.'
    end
    if action == 'release' && !%w[github play both].include?(destination)
      raise ArgumentError, 'Select github, play, or both.'
    end
    positive(env.fetch('PLAY_BUILD_RUN_ID', ''), 'build_run_id') if action == 'internal'
    if action == 'promote' && !env.fetch('PLAY_VERSION_CODE', '').strip.empty?
      positive(env.fetch('PLAY_VERSION_CODE').strip, 'version_code', MAX_CODE)
    end
    play = action == 'release' && destination != 'github'
    track = play ? options.fetch('track') : 'internal'
    raise ArgumentError, 'Play track must be internal or production.' unless %w[internal production].include?(track)

    build = action == 'build' || play
    website = pushed && action == 'release' && destination != 'play'
    { 'release_action' => action, 'release_destination' => destination, 'skip' => action == 'skip',
      'build_website' => website, 'setup_android' => build || website,
      'prepare_release' => action == 'release', 'build_android' => build,
      'prepare_signing' => build || action == 'verify', 'authenticate_play' => play || %w[verify internal promote].include?(action),
      'publish_bundle' => play || action == 'internal', 'play_track' => track, 'download_aab' => action == 'internal',
      'attach_apk' => action == 'release' && destination == 'both' }
  end

  def self.write_plan(env = ENV)
    plan = release_plan(env)
    File.open(env.fetch('GITHUB_OUTPUT'), 'a:UTF-8') do |file|
      plan.each { |key, value| file.puts "#{key}=#{value}" }
    end
    File.open(env.fetch('GITHUB_ENV'), 'a:UTF-8') do |file|
      file.puts "RELEASE_ACTION=#{plan.fetch('release_action')}", "RELEASE_DESTINATION=#{plan.fetch('release_destination')}",
                "PLAY_TRACK=#{plan.fetch('play_track')}"
    end
    puts "Selected #{plan.fetch('release_action')}: #{plan.fetch('release_destination')}, Play track #{plan.fetch('play_track')}."
    plan
  end

  class Github
    def initialize(env = ENV, transport: nil)
      @token = env.fetch('GITHUB_TOKEN')
      @base = "https://api.github.com/repos/#{REPOSITORY}"
      @transport = transport || method(:send_request)
    end

    def request(method, endpoint, body = nil, optional: false, upload: false)
      uri = URI(upload ? endpoint : @base + endpoint)
      if upload && (uri.scheme != 'https' || uri.host != 'uploads.github.com' || uri.port != 443 ||
                    !uri.path.start_with?("/repos/#{REPOSITORY}/releases/"))
        raise ArgumentError, 'Unexpected GitHub upload URL; credentials were not sent.'
      end
      request = Net::HTTPGenericRequest.new(method, !body.nil?, true, uri.request_uri)
      request['Authorization'] = "Bearer #{@token}"
      request['Accept'] = 'application/vnd.github+json'
      request['X-GitHub-Api-Version'] = '2022-11-28'
      request['User-Agent'] = 'anonymous-messenger-release'
      if upload
        request['Content-Type'] = endpoint.include?('.json') ? 'application/json' : 'application/vnd.android.package-archive'
        request.content_length = body.stat.size
        request.body_stream = body
      elsif !body.nil?
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate(body)
      end
      response = @transport.call(uri, request, upload ? 300 : 30)
      status = response.code.to_i
      return nil if optional && status == 404
      # Net::HTTP never follows redirects here. Never forward credentials or report API response bodies.
      raise ArgumentError, 'Unexpected GitHub redirect; credentials were not forwarded.' if status.between?(300, 399)
      raise ArgumentError, "GitHub #{method} failed (HTTP #{status})." unless status.between?(200, 299)

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise ArgumentError, 'GitHub returned an invalid JSON response.'
    end

    private

    def send_request(uri, request, timeout)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: timeout, write_timeout: timeout) do |http|
        http.request(request)
      end
    end
  end

  def self.tag_commit(api, tag)
    ref = api.request('GET', "/git/ref/tags/#{tag}", optional: true)
    return nil unless ref

    object = ref.fetch('object', {})
    6.times do
      break unless object.fetch('sha', '').match?(/\A[a-f0-9]{40}\z/)
      return object['sha'] if object['type'] == 'commit'
      break unless object['type'] == 'tag'

      object = api.request('GET', "/git/tags/#{object.fetch('sha')}").fetch('object', {})
    end
    raise ArgumentError, 'Cannot resolve version tag to an immutable source commit.'
  end

  def self.prepare_github(api, destination, root: ROOT, env: ENV)
    context(env)
    info = release_info(destination, root) # Validate both destinations before any GitHub mutation.
    tag = "v#{info.fetch('name')}"
    sha = env.fetch('GITHUB_SHA')
    existing = tag_commit(api, tag)
    if existing && existing != sha
      raise ArgumentError, "#{tag} points to different code. Bump the version; existing tags are never moved."
    end
    unless existing
      api.request('POST', '/git/refs', { 'ref' => "refs/tags/#{tag}", 'sha' => sha })
      raise ArgumentError, 'Version tag did not resolve to the workflow source commit.' unless tag_commit(api, tag) == sha
    end
    unless destination == 'play'
      release = api.request('GET', "/releases/tags/#{tag}", optional: true)
      body = nil
      if !release || release['body'].to_s.strip.empty?
        generated = api.request('POST', '/releases/generate-notes', { 'tag_name' => tag, 'target_commitish' => sha })
        body = info.fetch('github_notes') + "\n\n" + generated.fetch('body', '').strip
      end
      if !release
        release = api.request('POST', '/releases', { 'tag_name' => tag, 'target_commitish' => sha, 'name' => tag,
                                                  'body' => body, 'draft' => false, 'prerelease' => false, 'make_latest' => 'false' })
      elsif release['draft'] || body
        changes = { 'draft' => false }
        changes['make_latest'] = 'false' if release['draft']
        changes['body'] = body if body
        release = api.request('PATCH', "/releases/#{positive(release.fetch('id'), 'release ID')}", changes)
      end
      unless release['tag_name'] == tag && release['draft'] == false
        raise ArgumentError, 'GitHub Release was not published. Android release has stopped.'
      end
      puts "GitHub Release #{tag} published for #{sha}; Android steps may now proceed."
    end
    info
  end

  def self.write_json(path, value)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(value) + "\n", encoding: 'UTF-8')
  end

  def self.fingerprint(value)
    result = value.to_s.delete(':').downcase
    unless result.match?(/\A[a-f0-9]{64}\z/)
      raise ArgumentError, 'Configure Messenger PLAY_APP_SIGNING_SHA256 from Play Console app signing key certificate.'
    end
    result
  end

  def self.execute(args, env: {}, capture: false, timeout: nil, chdir: nil)
    # Argument arrays only; signing passwords stay in the environment. Captured preflight output is never logged.
    options = chdir ? { chdir: chdir } : {}
    Open3.popen3(env, *args, **options) do |stdin, stdout, stderr, waiter|
      stdin.close
      readers = [Thread.new { capture ? stdout.read : IO.copy_stream(stdout, $stdout) },
                 Thread.new { capture ? stderr.read : IO.copy_stream(stderr, $stderr) }]
      unless waiter.join(timeout)
        Process.kill('KILL', waiter.pid)
        waiter.join
        readers.each(&:value)
        raise CommandError, "Command timed out: #{File.basename(args.first)}."
      end
      output = readers.map(&:value)
      unless waiter.value.success?
        raise CommandError, "Command failed: #{File.basename(args.first)} (exit #{waiter.value.exitstatus})."
      end
      capture ? output.first : nil
    end
  end

  def self.prepare_ci(env = ENV, root: ROOT, run: method(:execute), filename: 'messenger-upload.keystore', path_variable: 'CI_KEYSTORE_PATH')
    keys = %w[PLAY_UPLOAD_KEYSTORE_BASE64 PLAY_UPLOAD_KEYSTORE_PASSWORD PLAY_UPLOAD_KEY_ALIAS PLAY_UPLOAD_KEY_PASSWORD
              PLAY_UPLOAD_CERT_SHA256 RUNNER_TEMP GITHUB_ENV]
    missing = keys.select { |key| env.fetch(key, '').strip.empty? }
    raise ArgumentError, "Missing CI configuration: #{missing.join(', ')}" unless missing.empty?

    expected = fingerprint(env.fetch('PLAY_UPLOAD_CERT_SHA256'))
    begin
      raw = Base64.strict_decode64(env.fetch('PLAY_UPLOAD_KEYSTORE_BASE64').gsub(/\s/, ''))
    rescue ArgumentError
      raise ArgumentError, 'PLAY_UPLOAD_KEYSTORE_BASE64 must contain valid Base64.'
    end
    raise ArgumentError, 'Upload keystore is empty.' if raw.empty?

    store = File.join(env.fetch('RUNNER_TEMP'), filename)
    File.open(store, 'wb', 0o600) { |file| file.write(raw) }
    File.chmod(0o600, store)
    begin
      private_env = env.to_h.merge('CI_KEYSTORE_PASSWORD' => env.fetch('PLAY_UPLOAD_KEYSTORE_PASSWORD'),
        'CI_KEYSTORE_ALIAS' => env.fetch('PLAY_UPLOAD_KEY_ALIAS'), 'CI_KEY_PASSWORD' => env.fetch('PLAY_UPLOAD_KEY_PASSWORD'))
      run.call(['java', File.join(root, 'scripts/VerifyUploadKey.java'), store, expected], env: private_env, capture: true, timeout: 45)
    rescue CommandError, SystemCallError
      FileUtils.rm_f(store)
      raise ArgumentError, 'Messenger upload-key verification failed. Check keystore, alias, passwords and registered upload SHA-256.'
    end
    File.open(env.fetch('GITHUB_ENV'), 'a:UTF-8') { |file| file.puts "#{path_variable}=#{store}" }
    puts 'Messenger private upload key and certificate verified; private credentials are not logged.'
  end

  def self.record_build(root: ROOT, env: ENV, run: method(:execute))
    context(env)
    version = version_info(root)
    actual_sha = run.call(['git', 'rev-parse', 'HEAD'], capture: true, chdir: root).strip
    raise ArgumentError, 'Build checkout differs from the workflow source.' unless actual_sha == env.fetch('GITHUB_SHA')

    verify_bundle(File.join(root, AAB), version, env: env, root: root, run: run)
    info = version.merge('source_sha' => env.fetch('GITHUB_SHA'), 'aab_sha256' => sha256_file(File.join(root, AAB)),
      'schema' => 1, 'repository_id' => REPOSITORY_ID, 'workflow' => WORKFLOW, 'branch' => BRANCH,
      'run_id' => positive(env.fetch('GITHUB_RUN_ID'), 'run ID'), 'run_attempt' => positive(env.fetch('GITHUB_RUN_ATTEMPT'), 'run attempt'),
      'variant' => 'prodStoreRelease', 'upload_certificate_sha256' => fingerprint(env.fetch('PLAY_UPLOAD_CERT_SHA256')))
    write_json(File.join(root, File.dirname(AAB), 'release-build.json'), info)
    info
  end

  def self.resolve_build(api, run_id, env = ENV)
    context(env)
    positive(run_id, 'build_run_id')
    run = api.request('GET', "/actions/runs/#{run_id}")
    unless run.dig('repository', 'id').to_s == REPOSITORY_ID && run['path'] == WORKFLOW &&
           %w[workflow_dispatch push].include?(run['event']) && run['head_branch'] == BRANCH &&
           run.dig('head_repository', 'id').to_s == REPOSITORY_ID && run['status'] == 'completed' &&
           run['conclusion'] == 'success' && run.fetch('head_sha', '').match?(/\A[a-f0-9]{40}\z/)
      raise ArgumentError, 'Choose a successful Messenger build from this workflow on main (push or manual dispatch).'
    end
    sha = run.fetch('head_sha')
    artifacts = api.request('GET', "/actions/runs/#{run_id}/artifacts?per_page=100")
    matches = artifacts.fetch('artifacts', []).select { |item| item['name'] == "anonymous-messenger-#{sha}" && !item['expired'] }
    raise ArgumentError, 'The run must contain exactly one unexpired Messenger AAB artifact.' unless matches.length == 1

    artifact = matches.first
    positive(artifact.fetch('id'), 'artifact ID')
    unless artifact.fetch('digest', '').match?(/\Asha256:[a-f0-9]{64}\z/)
      raise ArgumentError, 'The artifact needs a GitHub SHA-256 digest.'
    end
    source = Dir.mktmpdir('messenger-build-source-', env.fetch('RUNNER_TEMP'))
    read = lambda do |path, optional = false|
      file = api.request('GET', "/contents/#{path}?ref=#{sha}", optional: optional)
      next unless file
      unless file['type'] == 'file' && file['encoding'] == 'base64'
        raise ArgumentError, 'Cannot read the selected build source files.'
      end
      target = File.join(source, path)
      FileUtils.mkdir_p(File.dirname(target))
      File.binwrite(target, Base64.strict_decode64(file.fetch('content').gsub(/\s/, '')))
    end
    read.call('app/build.gradle.kts')
    read.call('app/gradle.properties')
    version = version_info(source)
    locales = api.request('GET', "/contents/fastlane/metadata/android?ref=#{sha}", optional: true)
    raise ArgumentError, 'The original build source has no committed Play notes.' unless locales.is_a?(Array)

    locales.each do |locale|
      next unless locale['type'] == 'dir'

      language = locale.fetch('name')
      unless language.match?(/\A[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z/)
        raise ArgumentError, 'Invalid Play locale in the original source commit.'
      end
      read.call("fastlane/metadata/android/#{language}/changelogs/#{version.fetch('code')}.txt", language != 'en-US')
    end
    release_info('play', source) # Fail before downloading/uploading an unpublishable artifact.
    result = { 'source' => source, 'sha' => sha, 'version' => version, 'artifact_id' => artifact.fetch('id'),
               'run_id' => run_id.to_s, 'run_attempt' => positive(run.fetch('run_attempt'), 'run attempt') }
    write_json(File.join(env.fetch('RUNNER_TEMP'), 'selected-build.json'), result)
    File.open(env.fetch('GITHUB_ENV'), 'a:UTF-8') do |file|
      file.puts "PLAY_RELEASE_SOURCE=#{source}", "PLAY_AAB_ARTIFACT_ID=#{artifact.fetch('id')}"
    end
    puts "Using original Play notes and AAB from run #{run_id}, source #{sha}."
    result
  end

  def self.verify_build(root: ROOT, env: ENV, run: method(:execute))
    selected = JSON.parse(read_text(File.join(env.fetch('RUNNER_TEMP'), 'selected-build.json')))
    recorded = JSON.parse(read_text(File.join(root, File.dirname(AAB), 'release-build.json')))
    expected = selected.fetch('version').merge('source_sha' => selected.fetch('sha'), 'aab_sha256' => sha256_file(File.join(root, AAB)),
      'schema' => 1, 'repository_id' => REPOSITORY_ID, 'workflow' => WORKFLOW, 'branch' => BRANCH,
      'run_id' => selected.fetch('run_id'), 'run_attempt' => selected.fetch('run_attempt'), 'variant' => 'prodStoreRelease',
      'upload_certificate_sha256' => fingerprint(env.fetch('PLAY_UPLOAD_CERT_SHA256')))
    unless recorded == expected
      raise ArgumentError, 'AAB digest, package/version or source provenance does not match the original build.'
    end
    verify_bundle(File.join(root, AAB), selected.fetch('version'), env: env, root: ROOT, run: run)
    puts 'Original build AAB digest and package/version/source provenance verified.'
  end

  def self.prepare_saved_release(api, env = ENV)
    selected = JSON.parse(read_text(File.join(env.fetch('RUNNER_TEMP'), 'selected-build.json')))
    # New uploads from saved builds tag the original commit, never the dispatch checkout.
    prepare_github(api, 'play', root: selected.fetch('source'), env: env.to_h.merge('GITHUB_SHA' => selected.fetch('sha')))
  end

  def self.resolve_apk(api, info, env = ENV)
    context(env)
    tag = "v#{info.fetch('name')}"
    raise ArgumentError, 'APK release tag points at different source.' unless tag_commit(api, tag) == env.fetch('GITHUB_SHA')

    release = api.request('GET', "/releases/tags/#{tag}")
    unless release['tag_name'] == tag && release['draft'] == false
      raise ArgumentError, 'The GitHub Release must already be published.'
    end
    positive(release.fetch('id'), 'release ID')
    { 'name' => info.fetch('name'), 'code' => info.fetch('code'), 'tag' => tag,
      'source_sha' => env.fetch('GITHUB_SHA'), 'release_id' => release.fetch('id') }
  end

  def self.attach_apk(api, env = ENV, run: method(:execute))
    context(env)
    unless env['RELEASE_ACTION'] == 'release' && env['RELEASE_DESTINATION'] == 'both'
      raise ArgumentError, 'APK attachment runs only as part of Both.'
    end
    recorded = JSON.parse(read_text(File.join(env.fetch('RUNNER_TEMP'), 'play-apk-release.json')))
    raise ArgumentError, 'GitHub Release changed during APK processing.' unless resolve_apk(api, recorded, env) == recorded

    filename = "AnonymousMessenger-Play-#{recorded.fetch('name')}.apk"
    apk = File.join(env.fetch('RUNNER_TEMP'), 'play-release-apk', filename)
    verify_apk(apk, recorded, certificate: env.fetch('PLAY_APP_SIGNING_SHA256'), env: env, run: run)
    attach_asset(api, recorded.fetch('release_id'), apk)
  end

  def self.main(argv = ARGV)
    argv = argv.dup
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/release.rb notes github|play|both, or an internal workflow step. Use .\release --help and .\build --help on Windows.'
      opts.on('-h', '--help') { puts opts; return }
    end
    parser.parse!(argv)
    command = argv.shift
    positional = command == 'notes' ? argv.shift : nil
    raise ArgumentError, 'Unexpected command arguments.' unless argv.empty?

    case command
    when 'notes'
      puts JSON.pretty_generate(release_info(positional))
    when 'plan' then write_plan
    when 'prepare-ci' then prepare_ci
    when 'prepare-website' then prepare_website
    when 'publish-website' then publish_website(Github.new)
    when 'setup-tools' then setup_bundletool
    when 'prepare-release'
      write_json(File.join(ENV.fetch('RUNNER_TEMP'), 'release-version.json'), prepare_github(Github.new, ENV.fetch('RELEASE_DESTINATION')))
    when 'record-build' then record_build
    when 'resolve-build' then resolve_build(Github.new, ENV.fetch('PLAY_BUILD_RUN_ID'))
    when 'verify-build'
      verify_build
      prepare_saved_release(Github.new)
    when 'resolve-apk'
      info = JSON.parse(read_text(File.join(ENV.fetch('RUNNER_TEMP'), 'release-version.json')))
      write_json(File.join(ENV.fetch('RUNNER_TEMP'), 'play-apk-release.json'), resolve_apk(Github.new, info))
    when 'attach-apk' then attach_apk(Github.new)
    else raise ArgumentError, "Choose a release command; use --help. Unknown command: #{command}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    MessengerRelease.main
  rescue ArgumentError, OptionParser::ParseError, KeyError, SystemCallError, IOError, MessengerRelease::CommandError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError => error
    warn "Release command failed: #{error.message}"
    exit 1
  end
end
