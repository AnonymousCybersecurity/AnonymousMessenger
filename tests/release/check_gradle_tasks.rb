# Execute the production Kotlin script in an isolated native Gradle fixture.
require_relative '../../scripts/release'

root = MessengerRelease::ROOT
wrapper = MessengerRelease.windows? ? [File.join(root, 'gradlew.bat')] : ['bash', File.join(root, 'gradlew')]
Dir.mktmpdir('gradle-release-', File.join(root, '.release-work').then { |p| File.directory?(p) ? p : nil }) do |project|
  File.write(File.join(project, 'settings.gradle.kts'), "rootProject.name = \"release-task-test\"\ninclude(\":app\")\n")
  script = File.join(root, 'gradle/release-tasks.gradle.kts').tr('\\', '/')
  File.write(File.join(project, 'build.gradle.kts'), "apply(from = \"#{script}\")\n")
  FileUtils.mkdir_p(File.join(project, 'app'))
  source = File.join(project, 'app/build.gradle.kts')
  File.write(source, <<~KOTLIN)
    val canonicalVersionCode = 261009 // keep this comment
    val canonicalVersionName = "26.10.09" // keep this alias
    val currentHotfixVersion = 0
    val maxHotfixVersions = 100
    val anonymousRevision = 6
    tasks.register("assembleProdStoreRelease")
    tasks.register("bundleProdStoreRelease")
  KOTLIN
  notes = [File.join(project, 'release-notes/26.10.09-7.md'), File.join(project, 'fastlane/metadata/android/en-US/changelogs/26100907.txt')]
  notes.each { |path| FileUtils.mkdir_p(File.dirname(path)); File.write(path, 'Already reviewed notes.') }
  gradle = lambda do |*args, success: true|
    output, status = Open3.capture2e(*(wrapper + ['-p', project, '--no-daemon', '--console=plain', *args]))
    raise output unless status.success? == success

    output
  end
  check = ->(condition) { raise 'Native Gradle preparation check failed.' unless condition }
  gradle.call('versionBump')
  check.call(File.read(source).include?('val anonymousRevision = 7'))
  check.call(File.read(source).include?('261009 // keep this comment'))
  check.call(notes.all? { |path| File.read(path) == 'Already reviewed notes.' })
  gradle.call('versionBump', '-PversionName=26.10.10-0', '-PversionCode=26101000')
  check.call(File.read(source).include?('val canonicalVersionName = "26.10.10" // keep this alias'))
  check.call(File.read(source).include?('val canonicalVersionCode = 261010'))
  check.call(File.read(source).include?('val anonymousRevision = 0'))
  check.call(File.read(File.join(project, 'release-notes/26.10.10-0.md')).include?('RELEASE_NOTES_TODO'))
  check.call(File.read(File.join(project, 'fastlane/metadata/android/en-US/changelogs/26101000.txt')).include?('RELEASE_NOTES_TODO'))
  before = File.binread(source)
  ['-PversionName=26.10.09-9', '-PversionCode=bad', '-PversionCode=26101100', '-PversionName=26.99.99-1'].each do |option|
    gradle.call('versionBump', option, success: false)
    check.call(File.binread(source) == before)
  end
  { 'buildLocalApk' => ['assembleProdStoreRelease'], 'buildLocalAab' => ['bundleProdStoreRelease'],
    'buildLocalBoth' => %w[assembleProdStoreRelease bundleProdStoreRelease] }.each do |task, targets|
    output = gradle.call(task, '--dry-run')
    check.call(targets.all? { |name| output.include?(":app:#{name} SKIPPED") })
  end
  puts 'Native Messenger bump, comments/preserved notes, new templates, invalid bumps and local variant routing passed.'
end
