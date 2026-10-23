require 'minitest/autorun'
require 'rexml/document'
require 'yaml'
require_relative '../../scripts/release'
require_relative '../../scripts/verify-google-identity'
require_relative '../../fastlane/release_config'

# Closed mocks: accidental real HTTP or CLI publishing is forbidden throughout these unit tests.
Net::HTTP.singleton_class.prepend(Module.new do
  def start(*)
    raise 'Real network forbidden in release tests'
  end
end)
Open3.singleton_class.prepend(Module.new do
  def popen3(*)
    raise 'Real subprocess forbidden in release unit tests'
  end
end)

class ReleaseApi
  attr_reader :responses, :calls

  def initialize(responses)
    @responses = Marshal.load(Marshal.dump(responses))
    @calls = []
  end

  def request(method, endpoint, body = nil, **)
    @calls << [method, endpoint, body]
    raise "Unexpected API operation: #{method} #{endpoint}" if @responses.empty?

    expected_method, expected_path, response = @responses.shift
    raise "Unexpected API operation: #{method} #{endpoint}, expected #{expected_path}" unless [method, endpoint] == [expected_method, expected_path]

    Marshal.load(Marshal.dump(response))
  end
end

class ReleaseTest < Minitest::Test
  R = MessengerRelease
  ID = MessengerIdentity
  SHA = 'a' * 40
  PIN = 'ab' * 32

  def setup
    @root = Dir.mktmpdir('messenger-release-test-', File.directory?(File.join(R::ROOT, '.release-work')) ? File.join(R::ROOT, '.release-work') : nil)
    @env = { 'GITHUB_REPOSITORY' => R::REPOSITORY, 'GITHUB_REPOSITORY_ID' => R::REPOSITORY_ID,
             'GITHUB_REF' => 'refs/heads/main', 'GITHUB_EVENT_NAME' => 'workflow_dispatch', 'GITHUB_SHA' => SHA,
             'RELEASE_ACTION' => 'release', 'RELEASE_DESTINATION' => 'both', 'PLAY_TRACK' => 'internal',
             'RUNNER_TEMP' => @root, 'GITHUB_ENV' => File.join(@root, 'env'), 'ANDROID_HOME' => File.join(@root, 'sdk'),
             'PLAY_APP_SIGNING_SHA256' => PIN }
    @gradle = File.join(@root, 'app/build.gradle.kts')
    write(@gradle, "val canonicalVersionCode = 261009 // retained comment\nval canonicalVersionName = \"26.10.09\"\nval currentHotfixVersion = 0\nval maxHotfixVersions = 100\nval anonymousRevision = 7\n")
    write(File.join(@root, 'app/gradle.properties'), "basePackageId=#{R::PACKAGE_NAME}\n")
    @env.merge!('PLAY_UPLOAD_CERT_SHA256' => PIN, 'GITHUB_RUN_ID' => '123', 'GITHUB_RUN_ATTEMPT' => '1')
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text, encoding: 'UTF-8')
  end

  def notes(github: "## Detailed Markdown\n\nFixed sync.", play: 'Improved photo sync.')
    write(File.join(@root, 'release-notes/26.10.09-7.md'), github)
    write(File.join(@root, 'fastlane/metadata/android/en-US/changelogs/26100907.txt'), play)
  end

  def prepare(api, destination = 'both')
    R.prepare_github(api, destination, root: @root, env: @env)
  end

  def ref
    { 'object' => { 'type' => 'commit', 'sha' => SHA } }
  end

  def published(**changes)
    { 'id' => 7, 'tag_name' => 'v26.10.09-7', 'draft' => false }.merge(changes.transform_keys(&:to_s))
  end

  def test_native_version_and_identity
    assert_equal({ 'package' => R::PACKAGE_NAME, 'name' => '26.10.09-7', 'code' => 26100907 }, R.version_info(@root))
    original = File.read(@gradle)
    [original.sub('canonicalVersionCode = 261009', 'canonicalVersionCode = 0'),
     original.sub('anonymousRevision = 7', 'anonymousRevision = 100'), original + "val anonymousRevision = 8\n"].each do |text|
      write(@gradle, text)
      assert_raises(ArgumentError) { R.version_info(@root) }
    end
  end

  def test_destination_notes_are_separate
    notes
    both = R.release_info('both', @root)
    assert_includes both.fetch('github_notes'), 'Markdown'
    assert_equal({ 'en-US' => 'Improved photo sync.' }, both.fetch('play_notes'))
    File.delete(File.join(@root, 'release-notes/26.10.09-7.md'))
    assert R.release_info('play', @root).key?('play_notes')
    assert_raises(ArgumentError) { R.release_info('both', @root) }
    notes
    File.delete(File.join(@root, 'fastlane/metadata/android/en-US/changelogs/26100907.txt'))
    assert R.release_info('github', @root).key?('github_notes')
    assert_raises(ArgumentError) { R.release_info('play', @root) }
  end

  def test_missing_blank_comment_only_or_unfinished_notes_stop_before_api
    ['', "  \n", "\u00a0", '<!-- notes -->', "# Changes\nRELEASE_NOTES_TODO", 'TODO: write summary', 'TBD', 'PLACEHOLDER'].each do |text|
      notes(play: text)
      api = ReleaseApi.new([])
      assert_raises(ArgumentError) { prepare(api) }
      assert_empty api.calls
    end
    File.delete(File.join(@root, 'fastlane/metadata/android/en-US/changelogs/26100907.txt'))
    api = ReleaseApi.new([])
    assert_raises(ArgumentError) { prepare(api) }
    assert_empty api.calls
  end

  def test_unicode_limit_and_additional_exact_locale
    notes(play: '😀' * 500)
    assert_equal 500, R.play_notes(26100907, @root).fetch('en-US').length
    notes(play: '😀' * 501)
    assert_raises(ArgumentError) { R.play_notes(26100907, @root) }
    notes(play: "\uFEFFImproved photo sync.\r\n")
    assert_equal 'Improved photo sync.', R.play_notes(26100907, @root).fetch('en-US')
    locale = File.join(@root, 'fastlane/metadata/android/fr-FR/changelogs/26100907.txt')
    write(locale, 'Synchronisation améliorée.')
    assert_equal 'Synchronisation améliorée.', R.play_notes(26100907, @root).fetch('fr-FR')
    write(locale, 'x' * 501)
    assert_raises(ArgumentError) { R.play_notes(26100907, @root) }
  end

  def test_historical_and_default_notes_do_not_substitute
    notes
    directory = File.join(@root, 'fastlane/metadata/android/en-US/changelogs')
    File.delete(File.join(directory, '26100907.txt'))
    write(File.join(directory, 'default.txt'), 'Fallback must never publish.')
    write(File.join(directory, '26100906.txt'), 'Old release.')
    assert_raises(ArgumentError) { R.play_notes(26100907, @root) }
  end

  def test_plan_all_release_choices_and_default_track
    %w[github play both].product(%w[internal production]).each do |destination, track|
      plan = R.release_plan(@env.merge('RELEASE_DESTINATION' => destination, 'PLAY_TRACK' => track))
      assert_equal destination != 'github', plan['build_android']
      assert_equal destination != 'github', plan['authenticate_play']
      assert_equal destination == 'both', plan['attach_apk']
      assert_equal destination == 'github' ? 'internal' : track, plan['play_track']
    end
    %w[verify build internal promote].each do |action|
      plan = R.release_plan(@env.merge('RELEASE_ACTION' => action, 'PLAY_BUILD_RUN_ID' => '123'))
      refute plan['prepare_release']
      refute plan['attach_apk']
      assert_equal action == 'build', plan['build_android']
    end
    assert_equal 'internal', R.release_plan(@env.reject { |key, _| key == 'PLAY_TRACK' })['play_track']
  end

  def test_context_and_invalid_inputs_are_rejected
    [{ 'GITHUB_EVENT_NAME' => 'push' }, { 'GITHUB_REF' => 'refs/tags/v26.10.09-7' },
     { 'GITHUB_REPOSITORY_ID' => '1016678903' }, { 'GITHUB_REPOSITORY' => 'fork/messenger' },
     { 'PLAY_TRACK' => 'beta' }, { 'RELEASE_ACTION' => 'internal', 'PLAY_BUILD_RUN_ID' => '' },
     { 'RELEASE_ACTION' => 'promote', 'PLAY_VERSION_CODE' => '2100000001' }].each do |changes|
      assert_raises(ArgumentError) { R.release_plan(@env.merge(changes)) }
    end
  end

  def push_env(message, changes: {}, commits: [])
    event = { 'deleted' => false, 'ref' => 'refs/heads/main', 'after' => SHA,
      'head_commit' => { 'id' => SHA, 'message' => message }, 'commits' => commits,
      'repository' => { 'id' => R::REPOSITORY_ID.to_i, 'full_name' => R::REPOSITORY } }.merge(changes)
    path = File.join(@root, 'event.json')
    write(path, JSON.generate(event))
    @env.merge('GITHUB_EVENT_NAME' => 'push', 'GITHUB_EVENT_PATH' => path)
  end

  def test_main_push_routes_to_website_or_selected_play_track
    { '' => ['github', 'internal', true, false], '[publish:github]' => ['github', 'internal', true, false],
      '[publish:play]' => ['play', 'production', false, true],
      '[publish:play:testtrack]' => ['play', 'internal', false, true],
      '[publish:both]' => ['both', 'production', true, true],
      '[publish:both:testtrack]' => ['both', 'internal', true, true] }.each do |marker, expected|
      plan = R.release_plan(push_env("Improve messaging #{marker}"))
      assert_equal expected, plan.values_at('release_destination', 'play_track', 'build_website', 'build_android'), marker
      assert plan['prepare_release']
      assert plan['setup_android']
      assert_equal expected[3], plan['authenticate_play']
      assert_equal expected[3], plan['publish_bundle']
      assert_equal expected[0] == 'both', plan['attach_apk']
    end
    assert_equal 'production', R.release_plan(push_env("Improve messaging\n\n[PUBLISH:PLAY]"))['play_track']
  end

  def test_skip_ci_stops_every_build_and_publication_even_with_publish_marker
    ['[skip ci]', '[ci skip]', '[no ci]', '[skip actions]', '[actions skip]', "\n\nskip-checks: true"].each do |skip|
      plan = R.release_plan(push_env("Release [publish:both] #{skip}"))
      assert plan['skip']
      %w[setup_android prepare_release build_website build_android prepare_signing authenticate_play publish_bundle attach_apk].each do |step|
        refute plan.fetch(step), step
      end
    end
    plan = R.release_plan(push_env('[publish:play]', commits: [{ 'message' => 'Docs [skip ci]' }]))
    assert plan['skip'], 'GitHub skips a push containing any skip-marked commit'
  end

  def test_bad_or_conflicting_publish_markers_cannot_fall_back_to_production
    ['[publish:play:testtrak]', '[publish:both:production]', '[publish:]', '[publish:play', '[publish play]',
     '[publish:play] [publish:both]', '[publish:play] [publish:play]', '[publish:play] [publish:broken'].each do |message|
      assert_raises(ArgumentError, message) { R.release_plan(push_env(message)) }
    end
    assert_raises(ArgumentError) { R.release_plan(@env.merge('RELEASE_ACTION' => 'skip')) }
  end

  def test_only_the_tip_message_selects_a_destination_and_is_read_as_data
    env = push_env("Fix sync: `echo unsafe` $(echo unsafe) \"quoted\" \u{1F512}\n[unrelated:marker]",
      commits: [{ 'message' => 'Previous commit [publish:play]' }])
    assert_equal 'github', R.release_plan(env)['release_destination']
    env['GITHUB_OUTPUT'] = File.join(@root, 'outputs')
    plan = R.write_plan(env)
    exported = File.readlines(env.fetch('GITHUB_ENV'), chomp: true).map { |line| line.split('=', 2) }.to_h
    assert_equal({ 'RELEASE_ACTION' => 'release', 'RELEASE_DESTINATION' => 'github', 'PLAY_TRACK' => 'internal' }, exported)
    assert_includes File.read(env.fetch('GITHUB_OUTPUT')), 'build_website=true'
    assert_equal plan, R.release_plan(env.merge(exported))
  end

  def test_push_requires_matching_main_tip_and_original_repository
    [{ 'deleted' => true }, { 'head_commit' => nil }, { 'after' => 'b' * 40 },
     { 'head_commit' => { 'id' => 'b' * 40, 'message' => '[publish:play]' } },
     { 'ref' => 'refs/heads/feature' }, { 'repository' => { 'id' => 1, 'full_name' => R::REPOSITORY } }].each do |changes|
      assert_raises(ArgumentError) { R.release_plan(push_env('[publish:play]', changes: changes)) }
    end
    %w[pull_request release schedule].each do |event|
      assert_raises(ArgumentError) { R.release_plan(push_env('[publish:play]').merge('GITHUB_EVENT_NAME' => event)) }
    end
  end

  def test_both_push_validates_both_note_files_before_any_tag_or_release_api_call
    %w[[publish:both] [publish:both:testtrack]].each do |marker|
      env = push_env(marker)
      destination = R.release_plan(env).fetch('release_destination')
      notes(play: 'RELEASE_NOTES_TODO')
      api = ReleaseApi.new([])
      assert_raises(ArgumentError) { R.prepare_github(api, destination, root: @root, env: env) }
      assert_empty api.calls
      notes(github: 'RELEASE_NOTES_TODO')
      assert_raises(ArgumentError) { R.prepare_github(api, destination, root: @root, env: env) }
      assert_empty api.calls
    end
  end

  def test_github_first_creates_exact_tag_then_markdown_and_generated_changelog
    notes
    api = ReleaseApi.new([['GET', '/git/ref/tags/v26.10.09-7', nil], ['POST', '/git/refs', {}],
                          ['GET', '/git/ref/tags/v26.10.09-7', ref], ['GET', '/releases/tags/v26.10.09-7', nil],
                          ['POST', '/releases/generate-notes', { 'body' => "## What changed\n* Generated PR" }],
                          ['POST', '/releases', published]])
    prepare(api)
    assert_equal({ 'ref' => 'refs/tags/v26.10.09-7', 'sha' => SHA }, api.calls[1][2])
    assert_equal "## Detailed Markdown\n\nFixed sync.\n\n## What changed\n* Generated PR", api.calls.last[2]['body']
    assert_equal 'false', api.calls.last[2]['make_latest']
    assert_empty api.responses
  end

  def test_existing_lightweight_or_annotated_tag_and_nonempty_release_preserved
    notes
    [false, true].each do |annotated|
      responses = [['GET', '/git/ref/tags/v26.10.09-7', { 'object' => { 'type' => annotated ? 'tag' : 'commit', 'sha' => SHA } }]]
      responses << ['GET', "/git/tags/#{SHA}", ref] if annotated
      responses << ['GET', '/releases/tags/v26.10.09-7', published(body: 'Existing description')]
      api = ReleaseApi.new(responses)
      prepare(api, 'github')
      assert api.calls.all? { |call| call.first == 'GET' }
    end
  end

  def test_existing_draft_preserves_notes_and_is_published
    notes
    api = ReleaseApi.new([['GET', '/git/ref/tags/v26.10.09-7', ref],
                          ['GET', '/releases/tags/v26.10.09-7', published(draft: true, body: 'Keep this')],
                          ['PATCH', '/releases/7', published]])
    prepare(api, 'github')
    assert_equal({ 'draft' => false, 'make_latest' => 'false' }, api.calls.last[2])
  end

  def test_blank_existing_release_receives_markdown_and_generated_notes
    notes
    api = ReleaseApi.new([['GET', '/git/ref/tags/v26.10.09-7', ref], ['GET', '/releases/tags/v26.10.09-7', published(body: '  ')],
                          ['POST', '/releases/generate-notes', { 'body' => 'Generated changelog' }], ['PATCH', '/releases/7', published]])
    prepare(api, 'github')
    assert_equal "## Detailed Markdown\n\nFixed sync.\n\nGenerated changelog", api.calls.last[2]['body']
  end

  def test_unfinished_github_notes_stop_both_before_tagging
    notes(github: "# Changes\nRELEASE_NOTES_TODO: Write notes")
    api = ReleaseApi.new([])
    assert_raises(ArgumentError) { prepare(api) }
    assert_empty api.calls
  end

  def test_tag_conflicts_never_mutate
    notes
    api = ReleaseApi.new([['GET', '/git/ref/tags/v26.10.09-7', { 'object' => { 'type' => 'commit', 'sha' => 'b' * 40 } }]])
    error = assert_raises(ArgumentError) { prepare(api) }
    assert_includes error.message, 'never moved'
    assert_equal 1, api.calls.length
  end

  def test_play_only_creates_tag_without_github_page
    notes
    api = ReleaseApi.new([['GET', '/git/ref/tags/v26.10.09-7', ref]])
    prepare(api, 'play')
    assert_equal 1, api.calls.length
  end

  def test_build_records_digest_and_immutable_source_without_notes
    aab = File.join(@root, R::AAB)
    write(aab, 'signed test bundle')
    R.stub(:verify_bundle, true) do
      info = R.record_build(root: @root, env: @env, run: ->(*, **) { SHA })
      R.write_json(File.join(@root, 'selected-build.json'), { 'version' => R.version_info(@root), 'sha' => SHA, 'run_id' => '123', 'run_attempt' => '1' })
      R.verify_build(root: @root, env: @env)
      assert_equal SHA, info['source_sha']
      assert_equal 'prodStoreRelease', info['variant']
      assert_raises(ArgumentError) { R.record_build(root: @root, env: @env, run: ->(*, **) { 'b' * 40 }) }
      write(aab, 'tampered')
      assert_raises(ArgumentError) { R.verify_build(root: @root, env: @env) }
    end
  end

  def build_api(notes: 'Original build notes', changes: {})
    run = { 'repository' => { 'id' => R::REPOSITORY_ID.to_i }, 'head_repository' => { 'id' => R::REPOSITORY_ID.to_i },
            'event' => 'workflow_dispatch', 'head_branch' => 'main', 'status' => 'completed', 'conclusion' => 'success',
            'path' => R::WORKFLOW, 'head_sha' => SHA, 'run_attempt' => 1 }.merge(changes)
    file = ->(text) { { 'type' => 'file', 'encoding' => 'base64', 'content' => Base64.encode64(text) } }
    ReleaseApi.new([['GET', '/actions/runs/123', run],
                    ['GET', '/actions/runs/123/artifacts?per_page=100', { 'artifacts' => [{ 'id' => 5, 'name' => "anonymous-messenger-#{SHA}", 'expired' => false, 'digest' => 'sha256:' + 'c' * 64 }] }],
                    ['GET', "/contents/app/build.gradle.kts?ref=#{SHA}", file.call(File.read(@gradle))],
                    ['GET', "/contents/app/gradle.properties?ref=#{SHA}", file.call("basePackageId=#{R::PACKAGE_NAME}\n")],
                    ['GET', "/contents/fastlane/metadata/android?ref=#{SHA}", [{ 'type' => 'dir', 'name' => 'en-US' }]],
                    ['GET', "/contents/fastlane/metadata/android/en-US/changelogs/26100907.txt?ref=#{SHA}", file.call(notes)]])
  end

  def test_reuse_and_fastlane_read_notes_from_original_commit
    notes(play: 'Newer checkout notes must not be used')
    api = build_api
    selected = R.resolve_build(api, '123', @env)
    assert_equal({ 'en-US' => 'Original build notes' }, R.play_notes(26100907, selected.fetch('source')))
    assert_equal({ 'en-US' => 'Original build notes' }, R.info(root: selected.fetch('source')).fetch('play_notes'))
    assert_includes File.read(File.join(@root, 'env')), 'PLAY_AAB_ARTIFACT_ID=5'
    assert_empty api.responses
  end

  def test_reuse_accepts_successful_main_push_build_with_original_notes
    selected = R.resolve_build(build_api(changes: { 'event' => 'push' }), '123', @env)
    assert_equal SHA, selected.fetch('sha')
    assert_equal({ 'en-US' => 'Original build notes' }, R.play_notes(26100907, selected.fetch('source')))
  end

  def test_saved_upload_tags_original_source_even_when_dispatch_checkout_is_newer
    notes
    api = build_api
    R.resolve_build(api, '123', @env)
    tag_api = ReleaseApi.new([['GET', '/git/ref/tags/v26.10.09-7', nil], ['POST', '/git/refs', {}],
                             ['GET', '/git/ref/tags/v26.10.09-7', ref]])
    R.prepare_saved_release(tag_api, @env.merge('GITHUB_SHA' => 'b' * 40))
    assert_equal SHA, tag_api.calls[1][2]['sha']
    assert_empty tag_api.responses
  end

  def test_website_assets_keep_the_existing_updater_identity_and_only_then_become_latest
    notes
    apk = File.join(@root, R::WEBSITE_APK)
    write(apk, 'verified website APK')
    responses = [['GET', '/git/ref/tags/v26.10.09-7', ref], ['GET', '/releases/tags/v26.10.09-7', published],
                 ['PATCH', '/releases/7', published]]
    attached = []
    R.stub(:verify_apk, true) do
      R.stub(:attach_asset, ->(_api, _id, path) { attached << path }) do
        api = ReleaseApi.new(responses)
        R.publish_website(api, @env, root: @root)
        assert_equal({ 'make_latest' => 'true' }, api.calls.last[2])
      end
    end
    assert_equal [apk, File.join(@root, 'index-v1.json')], attached
    index = JSON.parse(File.read(attached.last))
    assert_equal 26100907, index.fetch('apps').first.fetch('suggestedVersionCode')
    update = index.fetch('packages').fetch(R::PACKAGE_NAME).first
    assert_equal R::WEBSITE_APK, update.fetch('apkName')
    assert_equal R.sha256_file(apk), update.fetch('hash')
  end

  def test_reuse_rejects_unsuccessful_wrong_branch_fork_or_workflow
    [{ 'conclusion' => 'failure' }, { 'status' => 'in_progress' }, { 'head_branch' => 'feature' },
     { 'event' => 'pull_request' }, { 'head_repository' => { 'id' => 1 } }, { 'path' => '.github/workflows/other.yml' }].each do |changes|
      assert_raises(ArgumentError) { R.resolve_build(build_api(changes: changes), '123', @env) }
    end
  end

  def test_reuse_rejects_original_unfinished_notes
    notes(play: 'Valid notes today cannot repair the original build')
    assert_raises(ArgumentError) { R.resolve_build(build_api(notes: 'RELEASE_NOTES_TODO'), '123', @env) }
  end

  def test_reuse_rejects_expired_duplicate_or_undigested_artifacts
    %w[expired duplicate digest].each do |kind|
      api = build_api
      artifacts = api.responses[1][2].fetch('artifacts')
      case kind
      when 'expired' then artifacts.first['expired'] = true
      when 'duplicate' then artifacts << artifacts.first.dup
      when 'digest' then artifacts.first.delete('digest')
      end
      assert_raises(ArgumentError) { R.resolve_build(api, '123', @env) }
    end
  end

  def apk_setup
    info = { 'name' => '26.10.09-7', 'code' => 26100907, 'tag' => 'v26.10.09-7', 'source_sha' => SHA, 'release_id' => 7 }
    R.write_json(File.join(@root, 'play-apk-release.json'), info)
    apk = File.join(@root, 'play-release-apk/AnonymousMessenger-Play-26.10.09-7.apk')
    write(apk, 'actual test APK bytes')
    asset = { 'name' => File.basename(apk), 'state' => 'uploaded', 'size' => File.size(apk), 'digest' => "sha256:#{R.sha256_file(apk)}" }
    responses = [['GET', '/git/ref/tags/v26.10.09-7', ref], ['GET', '/releases/tags/v26.10.09-7', published]]
    runner = lambda do |args, **|
      args.include?('verify') ? "Signer #1 certificate SHA-256 digest: #{PIN}\n" :
        "package: name='#{R::PACKAGE_NAME}' versionCode='26100907' versionName='26.10.09-7'\n"
    end
    [responses, asset, runner]
  end

  def test_actual_apk_verified_then_uploaded_and_identical_retry_reused
    [false, true].each do |retrying|
      responses, asset, runner = apk_setup
      responses << ['GET', '/releases/7/assets?per_page=100&page=1', retrying ? [asset] : []]
      responses << ['POST', "https://uploads.github.com/repos/#{R::REPOSITORY}/releases/7/assets?name=#{asset['name']}", asset] unless retrying
      api = ReleaseApi.new(responses)
      assert_equal asset, R.attach_apk(api, @env, run: runner)
      assert_empty api.responses
    end
  end

  def test_actual_apk_wrong_certificate_identity_version_split_debug_or_signature_is_rejected
    responses, _, valid = apk_setup
    %w[certificate multiple-signers package version versionName split debug signature].each do |incorrect|
      runner = lambda do |args, **|
        raise R::CommandError, 'Mock signature failure' if incorrect == 'signature'

        result = valid.call(args)
        if args.include?('verify')
          result = result.sub(PIN, 'cd' * 32) if incorrect == 'certificate'
          result += "Signer #2 certificate SHA-256 digest: #{PIN}\n" if incorrect == 'multiple-signers'
        else
          result = result.sub(R::PACKAGE_NAME, 'another.package') if incorrect == 'package'
          result = result.sub("versionCode='26100907'", "versionCode='26100906'") if incorrect == 'version'
          result = result.sub("versionName='26.10.09-7'", "versionName='26.10.09-6'") if incorrect == 'versionName'
          result = result.strip + " split='config.arm64'\n" if incorrect == 'split'
          result += "application-debuggable\n" if incorrect == 'debug'
        end
        result
      end
      api = ReleaseApi.new(responses)
      assert_raises(ArgumentError) { R.attach_apk(api, @env, run: runner) }
      assert_equal 2, api.calls.length
    end
  end

  def test_conflicting_apk_asset_never_overwritten
    responses, asset, runner = apk_setup
    responses << ['GET', '/releases/7/assets?per_page=100&page=1', [asset.merge('digest' => 'sha256:' + 'c' * 64)]]
    api = ReleaseApi.new(responses)
    error = assert_raises(ArgumentError) { R.attach_apk(api, @env, run: runner) }
    assert_includes error.message, 'never overwritten'
    assert api.calls.all? { |call| call.first == 'GET' }
  end

  def test_ci_preflight_checks_key_before_writing_configuration
    env = @env.merge('PLAY_UPLOAD_KEYSTORE_BASE64' => Base64.strict_encode64('test store'), 'PLAY_UPLOAD_KEYSTORE_PASSWORD' => 'test',
                     'PLAY_UPLOAD_KEY_ALIAS' => 'test', 'PLAY_UPLOAD_KEY_PASSWORD' => 'test', 'PLAY_UPLOAD_CERT_SHA256' => PIN)
    calls = []
    R.prepare_ci(env, root: @root, run: ->(args, **options) { calls << [args, options] })
    assert_equal PIN, calls.first[0].last
    refute_includes calls.first[0], 'test'
    assert calls.first[1][:capture]
    assert_equal 'test', calls.first[1][:env]['CI_KEY_PASSWORD']
    assert_includes File.read(File.join(@root, 'env')), 'CI_KEYSTORE_PATH='
    assert_raises(ArgumentError) do
      R.prepare_ci(env, root: @root, run: ->(*) { raise R::CommandError, 'Mock key failure' })
    end
    refute File.exist?(File.join(@root, 'application.properties'))
    refute File.exist?(File.join(@root, 'messenger-upload.keystore'))
  end

  def test_combined_build_keystores_and_certificate_pins_stay_separate
    env = @env.merge('PLAY_UPLOAD_KEYSTORE_BASE64' => Base64.strict_encode64('play store'),
      'PLAY_UPLOAD_KEYSTORE_PASSWORD' => 'shared', 'PLAY_UPLOAD_KEY_ALIAS' => 'play', 'PLAY_UPLOAD_KEY_PASSWORD' => 'play-password',
      'KEYSTORE_B64' => Base64.strict_encode64('website store'), 'KEYSTORE_PASSWORD' => 'shared',
      'KEY_ALIAS' => 'website', 'KEY_PASSWORD' => 'website-password')
    calls = []
    runner = ->(args, **options) { calls << [args, options.fetch(:env)] }
    R.prepare_website(env, root: @root, run: runner)
    R.prepare_ci(env, root: @root, run: runner)
    paths = File.readlines(env.fetch('GITHUB_ENV'), chomp: true).map { |line| line.split('=', 2) }.to_h
    assert_equal 'website store', File.binread(paths.fetch('WEBSITE_KEYSTORE_PATH'))
    assert_equal 'play store', File.binread(paths.fetch('CI_KEYSTORE_PATH'))
    assert_equal [R::WEBSITE_CERT_SHA256, PIN], calls.map { |args, _| args.last }
    assert_equal %w[website play], calls.map { |_, private_env| private_env.fetch('CI_KEYSTORE_ALIAS') }
    assert_equal %w[website-password play-password], calls.map { |_, private_env| private_env.fetch('CI_KEY_PASSWORD') }
  end

  def provider
    { 'name' => ID::PROVIDER, 'state' => 'ACTIVE', 'oidc' => { 'issuerUri' => 'https://token.actions.githubusercontent.com' },
      'attributeMapping' => { 'google.subject' => 'assertion.sub', 'attribute.repository_id' => 'assertion.repository_id',
                              'attribute.repository_owner_id' => 'assertion.repository_owner_id' },
      'attributeCondition' => ID::CONDITION }
  end

  def test_provider_and_repo_restricted_account_validation
    ID.validate_provider(provider)
    [{ 'disabled' => true }, { 'attributeCondition' => 'true' }, { 'attributeMapping' => {} }, { 'state' => 'DELETED' },
     { 'attributeCondition' => "assertion.repository_owner_id == '264203613'" }].each do |changes|
      assert_raises(ArgumentError) { ID.validate_provider(provider.merge(changes)) }
    end
    policy = ->(members) { { 'bindings' => [{ 'role' => 'roles/iam.workloadIdentityUser', 'members' => members }] } }
    ID.validate_policy(policy.call([ID::MEMBER]))
    [[ID::MEMBER, 'allUsers'], [ID::MEMBER.sub('1198767196', '1016678903')], []].each do |members|
      assert_raises(ArgumentError) { ID.validate_policy(policy.call(members)) }
    end
  end

  def test_identity_variables_cannot_select_explorer_and_both_requires_messenger_pin
    env = @env.merge('GCP_WORKLOAD_IDENTITY_PROVIDER' => ID::PROVIDER, 'GCP_SERVICE_ACCOUNT' => ID::ACCOUNT)
    ID.configured(env)
    [{ 'GCP_SERVICE_ACCOUNT' => 'publish-explorer@graphene-play-publishing.iam.gserviceaccount.com' },
     { 'GCP_WORKLOAD_IDENTITY_PROVIDER' => 'different/provider' }, { 'PLAY_APP_SIGNING_SHA256' => '' }].each do |changes|
      assert_raises(ArgumentError) { ID.configured(env.merge(changes)) }
    end
  end

  def test_identity_remote_audit_uses_only_read_operations
    commands = []
    responses = [{ 'projectNumber' => ID::NUMBER, 'projectId' => ID::PROJECT }, provider, { 'email' => ID::ACCOUNT },
                 { 'bindings' => [{ 'role' => 'roles/iam.workloadIdentityUser', 'members' => [ID::MEMBER] }] },
                 %w[androidpublisher iam iamcredentials sts].map { |service| { 'config' => { 'name' => "#{service}.googleapis.com" } } }]
    ID.verify(run: lambda do |args, **|
      commands << args
      raise 'Unexpected gcloud operation' if responses.empty?

      JSON.generate(responses.shift)
    end)
    assert_empty responses
    assert_equal 5, commands.length
    assert commands.all? { |args| args.first == 'gcloud' && (args & %w[describe list get-iam-policy]).length == 1 }
  end

  def test_github_http_sends_json_and_streams_apk_without_redirecting_or_leaking_error_bodies
    calls = []
    response = Struct.new(:code, :body).new('200', '{"ok":true}')
    api = R::Github.new({ 'GITHUB_TOKEN' => 'test-token' }, transport: lambda do |uri, request, timeout|
      calls << [uri, request, timeout]
      response
    end)
    assert_equal({ 'ok' => true }, api.request('POST', '/git/refs', { 'sha' => SHA }))
    assert_equal "https://api.github.com/repos/#{R::REPOSITORY}/git/refs", calls.last[0].to_s
    assert_equal({ 'sha' => SHA }, JSON.parse(calls.last[1].body))
    assert_equal 'Bearer test-token', calls.last[1]['Authorization']
    path = File.join(@root, 'upload.apk')
    write(path, 'APK bytes')
    File.open(path, 'rb') do |file|
      api.request('POST', "https://uploads.github.com/repos/#{R::REPOSITORY}/releases/7/assets?name=test.apk", file, upload: true)
      assert_same file, calls.last[1].body_stream
      assert_equal File.size(path), calls.last[1].content_length
      assert_equal 300, calls.last[2]
      assert_raises(ArgumentError) { api.request('POST', 'https://example.test/upload', file, upload: true) }
    end
    response.code = '302'
    error = assert_raises(ArgumentError) { api.request('GET', '/releases') }
    assert_includes error.message, 'credentials were not forwarded'
    response.code, response.body = '403', 'secret-server-response'
    error = assert_raises(ArgumentError) { api.request('GET', '/releases') }
    refute_includes error.message, response.body
    response.code = '404'
    assert_nil api.request('GET', '/releases/tags/v26.10.09-7', optional: true)
  end

  def test_one_main_publishing_workflow_and_github_page_before_android_build
    text = File.read(File.join(R::ROOT, R::WORKFLOW))
    assert_includes text, 'workflow_dispatch:'
    workflow = YAML.load_file(File.join(R::ROOT, R::WORKFLOW))
    triggers = workflow['on'] || workflow.fetch(true) # Psych also recognizes YAML 1.1's boolean spelling.
    assert_equal ['main'], triggers.fetch('push').fetch('branches')
    website = YAML.load_file(File.join(R::ROOT, '.github/workflows/release-foss.yml'))
    website_triggers = website['on'] || website.fetch(true)
    refute website_triggers.key?('push')
    assert website_triggers.key?('pull_request')
    assert website_triggers.key?('workflow_dispatch')
    assert_operator text.index('scripts/release.rb prepare-release'), :<, text.index('fastlane android build_release')
    assert_equal 1, text.scan('fastlane android build_release').length
    %w[setup-python release.py verify-google-identity.py setup-node].each { |removed| refute_includes text, removed }
    refute_includes text, 'npm '
  end

  def test_push_routing_selects_actual_workflow_build_and_publish_steps_once
    workflow = YAML.load_file(File.join(R::ROOT, R::WORKFLOW))
    steps = workflow.fetch('jobs').fetch('release').fetch('steps')
    { '' => [1, 0], '[publish:play]' => [0, 1], '[publish:play:testtrack]' => [0, 1],
      '[publish:both]' => [1, 1], '[publish:both:testtrack]' => [1, 1], '[skip ci]' => [0, 0] }.each do |marker, counts|
      plan = R.release_plan(push_env(marker))
      commands = steps.filter_map do |step|
        condition = step['if']
        selected = !condition || condition == 'always()' || condition.split(' || ').any? do |clause|
          match = clause.match(/\Asteps\.plan\.outputs\.(\w+) == 'true'\z/)
          match && plan.fetch(match[1]) == true
        end
        step['run'] if selected
      end.join("\n")
      assert_equal counts, [commands.scan(':app:assembleProdWebsiteRelease').length, commands.scan('fastlane android build_release').length], marker
      assert_equal counts[0], commands.scan('scripts/release.rb publish-website').length
      assert_equal counts[1], commands.scan('fastlane android publish track:').length
      if counts[0] == 1
        assert_includes commands, 'env -u CI_KEYSTORE_PATH ./gradlew'
        assert_includes commands, '--ks "$WEBSITE_KEYSTORE_PATH"'
      end
    end
  end
end
