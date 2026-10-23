require 'minitest/autorun'
require_relative '../../scripts/release'

class ArtifactTest < Minitest::Test
  R = MessengerRelease
  INFO = { 'name' => '26.10.09-7', 'code' => 26100907 }.freeze
  PIN = 'ab' * 32

  def test_actual_bundle_manifest_is_checked_after_signature_and_structure
    xml = %(<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="#{R::PACKAGE_NAME}" android:versionCode="26100907" android:versionName="26.10.09-7"><application/></manifest>)
    [xml, xml.sub(R::PACKAGE_NAME, 'wrong.package'), xml.sub('26100907', '26100906'),
     xml.sub('26.10.09-7', '26.10.09-6'), xml.sub('<application/>', '<application android:debuggable="true"/>'),
     xml.sub('<application/>', '<application android:debuggable="1"/>'), xml.sub('<manifest ', '<manifest split="config.en" ')].each_with_index do |manifest, index|
      calls = []
      runner = ->(args, **) { calls << args; args.include?('manifest') ? manifest : '' }
      R.stub(:sha256_file, R::BUNDLETOOL_SHA256) do
        action = -> { R.verify_bundle('fixture.aab', INFO, env: { 'PLAY_UPLOAD_CERT_SHA256' => PIN, 'BUNDLETOOL_JAR' => 'bundletool.jar' }, run: runner) }
        index.zero? ? assert(action.call) : assert_raises(ArgumentError, &action)
      end
      assert_equal 3, calls.length
      assert_includes calls.first, PIN
      assert_includes calls[1], 'validate'
    end
  end

  def test_bundletool_checksum_and_failed_cryptographic_verification_stop_manifest_processing
    env = { 'PLAY_UPLOAD_CERT_SHA256' => PIN, 'BUNDLETOOL_JAR' => 'bundletool.jar' }
    R.stub(:sha256_file, '00' * 32) do
      assert_raises(ArgumentError) { R.verify_bundle('fixture.aab', INFO, env: env, run: ->(*) { raise 'Should not execute' }) }
    end
    R.stub(:sha256_file, R::BUNDLETOOL_SHA256) do
      assert_raises(ArgumentError) { R.verify_bundle('fixture.aab', INFO, env: env, run: ->(*, **) { raise R::CommandError, 'Invalid signature' }) }
    end
  end
end
