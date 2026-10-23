# Real Android/JDK tools, disposable keys/files, no HTTP or publishing.
require_relative '../../scripts/release'

r = MessengerRelease
sdk = ENV['ANDROID_HOME'] || ENV.fetch('ANDROID_SDK_ROOT')
tools = File.join(sdk, 'build-tools/36.0.0')
aapt = File.join(tools, r.windows? ? 'aapt2.exe' : 'aapt2')
platform = File.join(sdk, 'platforms/android-36.1/android.jar')
Dir.mktmpdir('artifact-check-') do |directory|
  store = File.join(directory, 'fixture.jks')
  certificate = File.join(directory, 'fixture.der')
  private_env = { 'CI_KEYSTORE_PASSWORD' => 'fixture-store-password', 'CI_KEY_PASSWORD' => 'fixture-key-password' }
  run = ->(args) { r.execute(args, env: private_env, capture: true, timeout: 120) }
  run.call(['keytool', '-genkeypair', '-storetype', 'JKS', '-keystore', store, '-alias', 'fixture',
            '-storepass:env', 'CI_KEYSTORE_PASSWORD', '-keypass:env', 'CI_KEY_PASSWORD', '-keyalg', 'RSA',
            '-keysize', '2048', '-validity', '2', '-dname', 'CN=Disposable artifact test'])
  run.call(['keytool', '-exportcert', '-keystore', store, '-alias', 'fixture', '-storepass:env', 'CI_KEYSTORE_PASSWORD', '-file', certificate])
  pin = r.sha256_file(certificate)
  info = { 'name' => '26.10.09-7', 'code' => 26100907 }
  reject = lambda do |&block|
    begin
      block.call
    rescue ArgumentError, r::CommandError
      next
    end
    raise 'Invalid artifact was accepted.'
  end
  make_apk = lambda do |extra = ''|
    manifest = File.join(directory, 'AndroidManifest.xml')
    xml = %(<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="#{r::PACKAGE_NAME}" android:versionCode="26100907" android:versionName="26.10.09-7" #{extra.include?('split=') ? extra : ''}><uses-sdk android:minSdkVersion="27"/><application android:debuggable="#{extra == 'debug' ? 'true' : 'false'}"/></manifest>)
    File.write(manifest, xml)
    unsigned = File.join(directory, 'unsigned.apk')
    apk = File.join(directory, 'fixture.apk')
    run.call([aapt, 'link', '-I', platform, '--manifest', manifest, '-o', unsigned])
    run.call(['java', '-jar', File.join(tools, 'lib/apksigner.jar'), 'sign', '--ks', store, '--ks-key-alias', 'fixture',
              '--ks-pass', 'env:CI_KEYSTORE_PASSWORD', '--key-pass', 'env:CI_KEY_PASSWORD', '--out', apk, unsigned])
    apk
  end
  apk = make_apk.call
  r.verify_apk(apk, info, certificate: pin)
  reject.call { r.verify_apk(apk, info, certificate: '00' * 32) }
  reject.call { r.verify_apk(apk, info.merge('name' => '26.10.09-6'), certificate: pin) }
  reject.call { r.verify_apk(apk, info.merge('code' => 26100906), certificate: pin) }
  reject.call { r.verify_apk(File.join(directory, 'unsigned.apk'), info, certificate: pin) }
  reject.call { r.verify_apk(make_apk.call('debug'), info, certificate: pin) }
  reject.call { r.verify_apk(make_apk.call('split="config.en"'), info, certificate: pin) }

  payload = File.join(directory, 'payload')
  FileUtils.mkdir_p(File.join(payload, 'base/manifest'))
  File.write(File.join(payload, 'base/manifest/AndroidManifest.xml'), 'signed manifest payload')
  File.write(File.join(payload, 'BundleConfig.pb'), 'signed config payload')
  bundle = File.join(directory, 'fixture.aab')
  run.call(['jar', '--create', '--file', bundle, '-C', payload, '.'])
  verify = ['java', File.join(r::ROOT, 'scripts/VerifyBundle.java'), bundle, pin]
  reject.call { run.call(verify) }
  run.call(['jarsigner', '-keystore', store, '-storepass:env', 'CI_KEYSTORE_PASSWORD', '-keypass:env', 'CI_KEY_PASSWORD', bundle, 'fixture'])
  run.call(verify)
  reject.call { run.call(verify[0...-1] + ['00' * 32]) }
  original = File.binread(bundle)
  FileUtils.mkdir_p(File.join(payload, 'META-INF'))
  File.write(File.join(payload, 'META-INF/unsigned.txt'), 'unsigned addition')
  run.call(['jar', '--update', '--file', bundle, '-C', payload, 'META-INF/unsigned.txt'])
  reject.call { run.call(verify) }
  File.binwrite(bundle, original)
  File.write(File.join(payload, 'BundleConfig.pb'), 'tampered config')
  run.call(['jar', '--update', '--file', bundle, '-C', payload, 'BundleConfig.pb'])
  reject.call { run.call(verify) }
  puts 'Actual APK signature/pin/version/debug/split checks and AAB wrong signer/unsigned addition/tampering checks passed.'
end
