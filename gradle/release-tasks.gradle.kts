import java.nio.file.Files
import java.nio.file.StandardOpenOption
import java.time.LocalDate

// Keep Messenger's production store variant and its existing signing environment.
mapOf(
  "buildLocalApk" to listOf(":app:assembleProdStoreRelease"),
  "buildLocalAab" to listOf(":app:bundleProdStoreRelease"),
  "buildLocalBoth" to listOf(":app:assembleProdStoreRelease", ":app:bundleProdStoreRelease")
).forEach { (name, targets) ->
  tasks.register(name) {
    group = "release"
    description = "Build signed prodStore release output(s) from current files; never publish."
    dependsOn(targets)
  }
}

tasks.register("versionBump") {
  group = "release"
  description = "Bump Messenger revision (YY.MM.DD-REV) and create separate note templates."
  doLast {
    val source = rootProject.file("app/build.gradle.kts")
    val text = source.readText()
    fun pattern(key: String) = Regex("(?m)^(val $key = )(\\d+)(?=\\s*(?://.*)?$)")
    fun number(key: String) = pattern(key).findAll(text).single().groupValues[2].toLong()
    val namePattern = Regex("(?m)^(val canonicalVersionName = )\"([^\"]+)\"")
    val oldName = namePattern.findAll(text).single().groupValues[2]
    val oldCanonical = number("canonicalVersionCode")
    val oldRevision = number("anonymousRevision")
    val oldHotfix = number("currentHotfixVersion")
    require(number("maxHotfixVersions") == 100L) { "Review changed Messenger versionCode formula before bumping." }
    val oldCode = oldCanonical * 100 + oldRevision + oldHotfix
    fun date(name: String): LocalDate {
      require(Regex("\\d{2}\\.\\d{2}\\.\\d{2}").matches(name)) { "Canonical version must be YY.MM.DD." }
      val parts = name.split('.').map { it.toInt() }
      return LocalDate.of(2000 + parts[0], parts[1], parts[2])
    }
    val requestedName = providers.gradleProperty("versionName").orNull
    val requestedCode = providers.gradleProperty("versionCode").orNull
    require(requestedCode == null || Regex("[1-9]\\d*").matches(requestedCode)) { "versionCode must be a positive integer." }
    val explicitCode = requestedCode?.toLongOrNull()
    require(requestedCode == null || explicitCode != null) { "versionCode is too large." }
    val newName = requestedName?.substringBeforeLast('-') ?: oldName
    val revision = if (requestedName != null) {
      require(Regex("\\d{2}\\.\\d{2}\\.\\d{2}-\\d{1,2}").matches(requestedName)) { "versionName must be YY.MM.DD-REV, with REV between 0 and 99." }
      requestedName.substringAfterLast('-').toLong()
    } else if (explicitCode != null) {
      require(explicitCode / 100 == oldCanonical) { "Changing the canonical code also requires --version-name." }
      explicitCode % 100
    } else oldRevision + oldHotfix + 1
    require(revision in 0..99L) { "Revision space exhausted; select the next canonical version and code explicitly." }
    require(date(newName) > date(oldName) || (newName == oldName && revision > oldRevision)) { "versionName must increase." }
    val canonical = explicitCode?.div(100) ?: if (newName == oldName) oldCanonical else newName.replace(".", "").toLong()
    val code = canonical * 100 + revision
    require(explicitCode == null || explicitCode == code) { "versionCode must equal canonicalVersionCode * 100 + revision; hotfix resets to zero." }
    require(code in (oldCode + 1)..2_100_000_000L) { "versionCode must increase and be at most 2100000000." }
    val fullName = "$newName-$revision"
    val github = rootProject.file("release-notes/$fullName.md")
    val play = rootProject.file("fastlane/metadata/android/en-US/changelogs/$code.txt")
    fun template(file: File, contents: String) {
      file.parentFile.mkdirs()
      if (!file.exists()) Files.writeString(file.toPath(), contents, StandardOpenOption.CREATE_NEW)
    }
    template(github, "# AnonymousMessenger $fullName\n\nRELEASE_NOTES_TODO: Write reviewed Markdown release notes.\n")
    template(play, "RELEASE_NOTES_TODO: Write a reviewed plain-text summary (maximum 500 Unicode characters).\n")
    var updated = namePattern.replace(text) { "${it.groupValues[1]}\"$newName\"" }
    mapOf("canonicalVersionCode" to canonical, "anonymousRevision" to revision, "currentHotfixVersion" to 0L).forEach { (key, value) ->
      updated = pattern(key).replace(updated) { "${it.groupValues[1]}$value" }
    }
    source.writeText(updated)
    logger.lifecycle("$oldName-$oldRevision ($oldCode) -> $fullName ($code). Review both notes, commit/push, then dispatch explicitly.")
  }
}
