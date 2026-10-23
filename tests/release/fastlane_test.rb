require 'minitest/autorun'
require 'tmpdir'
require 'json'
require_relative '../../fastlane/release_config'

module UI
  def self.message(_text); end
  def self.user_error!(text)
    raise ArgumentError, text
  end
end

# Evaluate the actual Fastfile with a closed action surface. No Fastlane/network action can escape.
class LaneHarness
  attr_reader :lanes, :uploads, :builds
  def initialize
    @lanes = {}
    @uploads = []
    @builds = []
    @tracks = { 'internal' => [26100906], 'production' => [26100905] }
    instance_eval(File.read(File.expand_path('../../fastlane/Fastfile', __dir__)), File.expand_path('../../fastlane/Fastfile', __dir__))
  end
  def default_platform(_name); end
  def platform(_name)
    yield
  end
  def desc(_text); end
  def lane(name, &block)
    @lanes[name] = block
  end
  def tracks=(value)
    @tracks = value
  end
  def google_play_track_version_codes(**options)
    raise 'Wrong package' unless options.fetch(:package_name) == MessengerRelease::PACKAGE_NAME
    @tracks.fetch(options.fetch(:track))
  end
  def gradle(**options)
    @builds << options
  end
  def upload_to_play_store(**options)
    if options[:metadata_path]
      directory = options[:metadata_path].tr('\\', '/')
      files = Dir.glob(File.join(directory, '**', '*.txt'))
      options[:observed_notes] = files.to_h { |file| [file.delete_prefix(directory + '/'), File.read(file)] }
    end
    @uploads << options
  end
end

class FastlaneTest < Minitest::Test
  INFO = { 'name' => '26.10.09-7', 'code' => 26100907, 'play_notes' => { 'en-US' => 'Original short notes', 'fr-FR' => 'Résumé original' } }.freeze

  def setup
    @harness = LaneHarness.new
    @original_env = ENV.to_h
    @temp = Dir.mktmpdir('messenger-lanes-', ENV['RUNNER_TEMP'])
    @aab_constant = MessengerRelease::AAB_PATH
    MessengerRelease.send(:remove_const, :AAB_PATH)
    MessengerRelease.const_set(:AAB_PATH, File.join(@temp, 'signed.aab'))
    File.write(MessengerRelease::AAB_PATH, 'test bundle')
    ENV['GOOGLE_APPLICATION_CREDENTIALS'] = File.join(@temp, 'credentials.json')
    File.write(ENV['GOOGLE_APPLICATION_CREDENTIALS'], '{}')
  end

  def teardown
    MessengerRelease.send(:remove_const, :AAB_PATH)
    MessengerRelease.const_set(:AAB_PATH, @aab_constant)
    ENV.replace(@original_env)
    FileUtils.remove_entry(@temp)
  end

  def test_internal_default_and_direct_production_send_only_exact_notes_with_existing_aab
    [{}, { track: 'production' }].each do |options|
      MessengerRelease.stub(:verify_bundle, true) { MessengerRelease.stub(:info, INFO) { @harness.lanes.fetch(:publish).call(options) } }
      upload = @harness.uploads.last
      assert_equal options.fetch(:track, 'internal'), upload[:track]
      assert_equal 'completed', upload[:release_status]
      assert_equal MessengerRelease::AAB_PATH, upload[:aab]
      assert_equal({ 'en-US/changelogs/26100907.txt' => 'Original short notes', 'fr-FR/changelogs/26100907.txt' => 'Résumé original' }, upload[:observed_notes])
      assert upload[:skip_upload_metadata]
      refute upload[:skip_upload_changelogs]
    end
    assert_empty @harness.builds
  end

  def test_invalid_track_never_publishes
    assert_raises(ArgumentError) { @harness.lanes.fetch(:publish).call(track: 'beta') }
    assert_empty @harness.uploads
  end

  def test_reused_version_code_is_rejected_before_supply
    @harness.tracks = { 'internal' => [26100907], 'production' => [26100905] }
    MessengerRelease.stub(:verify_bundle, true) { MessengerRelease.stub(:info, INFO) { assert_raises(ArgumentError) { @harness.lanes.fetch(:publish).call({}) } } }
    assert_empty @harness.uploads
  end

  def test_invalid_notes_stop_before_supply
    MessengerRelease.stub(:info, -> { raise ArgumentError, 'Original notes unfinished' }) do
      assert_raises(ArgumentError) { @harness.lanes.fetch(:publish).call({}) }
    end
    assert_empty @harness.uploads
  end

  def test_promote_latest_and_exact_without_build_or_local_notes
    @harness.tracks = { 'internal' => [26100906, 26100907], 'production' => [26100905] }
    [{}, { version_code: '26100906' }].each do |options|
      MessengerRelease.stub(:info, -> { raise 'Promotion must never read local notes' }) do
        @harness.lanes.fetch(:promote).call(options)
      end
      upload = @harness.uploads.last
      assert_equal options.fetch(:version_code, 26100907).to_i, upload[:version_code]
      assert_equal 'internal', upload[:track]
      assert_equal 'production', upload[:track_promote_to]
      assert upload[:skip_upload_aab]
      assert upload[:skip_upload_changelogs] # supply carries original TrackRelease.release_notes unchanged.
      refute upload.key?(:metadata_path)
    end
    assert_empty @harness.builds
  end

  def test_no_internal_unknown_code_and_superseded_production_fail
    [{ 'internal' => [], 'production' => [] }, { 'internal' => [26100906], 'production' => [26100906] }].each do |tracks|
      @harness.tracks = tracks
      assert_raises(ArgumentError) { @harness.lanes.fetch(:promote).call({}) }
    end
    @harness.tracks = { 'internal' => [26100906], 'production' => [26100905] }
    assert_raises(ArgumentError) { @harness.lanes.fetch(:promote).call(version_code: '26100907') }
    assert_empty @harness.uploads
  end

  def test_verify_is_read_only_and_never_builds
    @harness.lanes.fetch(:verify_access).call
    assert_empty @harness.uploads
    assert_empty @harness.builds
  end

  def test_build_checks_then_one_bundle_without_reading_notes
    MessengerRelease.stub(:info, -> { raise 'Build must not require completed notes' }) { @harness.lanes.fetch(:build_release).call }
    assert_equal 1, @harness.builds.length
    task = @harness.builds.first[:tasks]
    assert_includes task, ':app:testProdStoreDebugUnitTest'
    assert_includes task, ':app:lintProdStoreRelease'
    assert_equal 1, task.count(':app:bundleProdStoreRelease')
    assert_empty @harness.uploads
  end
end
