allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Backfills `namespace` for plugins that predate it.
//
// AGP 8 dropped the old `package` attribute in a library's AndroidManifest in
// favour of `namespace` in the build file, and fails configuration outright
// when neither is set. `on_audio_query_android` 1.1.0 was published before that
// and still declares only the manifest attribute, so the build dies with
// "Namespace not specified" before compiling a single line.
//
// The namespace it wants is exactly the manifest's `package`, which is what
// AGP's own upgrade assistant would have migrated — so read it back out and set
// it.
//
// Two details this has to get right:
//
//  * It hooks the moment the library plugin is applied, not `afterEvaluate`.
//    The block below forces evaluation via `evaluationDependsOn`, so by the
//    time an `afterEvaluate` callback could be registered some projects are
//    already evaluated and Gradle refuses it outright.
//  * Reflection, because AGP is not on the root project's classpath here
//    (settings.gradle.kts applies it with `apply false`), so naming its types
//    would not compile. A plugin that does declare a namespace configures it
//    after this runs and simply overwrites the value.
subprojects {
    plugins.withId("com.android.library") {
        val android = extensions.findByName("android") ?: return@withId
        val methods = android.javaClass.methods
        val getNamespace = methods.firstOrNull { it.name == "getNamespace" && it.parameterCount == 0 }
        val setNamespace = methods.firstOrNull { it.name == "setNamespace" && it.parameterCount == 1 }
        if (getNamespace == null || setNamespace == null) return@withId
        if (getNamespace.invoke(android) != null) return@withId

        val manifest = file("src/main/AndroidManifest.xml")
        if (!manifest.exists()) return@withId

        val declared = Regex("""package\s*=\s*"([^"]+)"""")
            .find(manifest.readText())
            ?.groupValues?.get(1)
            ?: return@withId

        logger.lifecycle("namespace backfilled for :${project.name} -> $declared")
        setNamespace.invoke(android, declared)
    }
}

// Pins every plugin module to the same JVM target as the app.
//
// Gradle refuses to build a module whose Java and Kotlin tasks disagree, and
// these plugins disagree by default: they declare an old Java level (11) while
// the Kotlin plugin, given no instruction, follows the JDK running Gradle (21).
//
// 17 is what `app/build.gradle.kts` compiles against, so everything lines up on
// that.
//
// Timing is the whole difficulty here, and the two sides need opposite answers.
//
// Java: it has to be written to the `android { compileOptions }` extension, and
// it has to be written from `afterEvaluate`. Two earlier attempts lost the race:
//
//  * from `plugins.withId`, we run before the module's own `android { }` block,
//    which then overwrites us — this is how `dynamic_color` held on to 1.8;
//  * on the `JavaCompile` tasks, we lose too, because AGP stamps them from
//    `compileOptions` in a configuration action registered after ours.
//
// `afterEvaluate` sits between the two: the module's `android { }` block has
// run, and AGP has not yet created its tasks (its own `afterEvaluate` is
// registered while the module applies the plugin, so it runs after this one,
// which is registered here at root-configuration time).
//
// Kotlin: the opposite — the target is a lazy `Property`, so writing it at task
// configuration is both sufficient and immune to ordering.
//
// Reflection throughout, because neither AGP nor the Kotlin plugin is on the
// root project's classpath (settings.gradle.kts applies them with `apply false`).
val jvmTarget = "17"
val javaVersion = JavaVersion.toVersion(jvmTarget)

fun alignJavaTarget(project: Project) {
    val android = project.extensions.findByName("android") ?: return
    val options = android.javaClass.methods
        .firstOrNull { it.name == "getCompileOptions" && it.parameterCount == 0 }
        ?.invoke(android) ?: return
    // `setSourceCompatibility` is overloaded (Object / JavaVersion / String);
    // the ones that don't accept a JavaVersion just throw and are ignored.
    options.javaClass.methods
        .filter { it.name == "setSourceCompatibility" || it.name == "setTargetCompatibility" }
        .forEach { setter -> runCatching { setter.invoke(options, javaVersion) } }
    project.logger.lifecycle("JVM target pinned to $jvmTarget for :${project.name}")
}

// Raises `compileSdk` on modules that pin one older than their own
// dependencies require.
//
// `on_audio_query_android` 1.1.0 declares `compileSdkVersion 33`, but resolves
// AndroidX artifacts (fragment 1.7.1, activity 1.8.1, window 1.2.0, lifecycle
// 2.7.0 …) whose AAR metadata demands 34 or later — sixteen violations, all the
// same cause. `checkDebugAarMetadata` is the task that enforces it.
//
// Raising compileSdk only widens the API surface the module may reference; it
// changes neither `minSdk` (which devices can install) nor `targetSdk` (which
// runtime behaviours the app opts into), so nothing about the app's behaviour
// moves. 36 matches what Flutter gives `:app`, and platforms 33→36.1 are
// already installed locally, so this downloads nothing.
//
// Only ever raises: a module already on 36 is left alone.
val minCompileSdk = 36

fun alignCompileSdk(project: Project) {
    val android = project.extensions.findByName("android") ?: return
    val methods = android.javaClass.methods
    val current = methods
        .firstOrNull { it.name == "getCompileSdk" && it.parameterCount == 0 }
        ?.invoke(android) as? Int
    if (current != null && current >= minCompileSdk) return

    val setter = methods.firstOrNull { it.name == "setCompileSdk" && it.parameterCount == 1 }
        ?: return
    runCatching { setter.invoke(android, minCompileSdk) }
        .onSuccess {
            project.logger.lifecycle(
                "compileSdk ${current ?: "?"} -> $minCompileSdk for :${project.name}"
            )
        }
}

subprojects {
    // Guard: a project Gradle has already evaluated refuses `afterEvaluate`.
    if (state.executed) {
        alignJavaTarget(project)
        alignCompileSdk(project)
    } else {
        afterEvaluate {
            alignJavaTarget(project)
            alignCompileSdk(project)
        }
    }

    // The Kotlin side is a Property<JvmTarget>, and JvmTarget is an enum that
    // only exists once the Kotlin plugin is on the classpath — hence the
    // lookup by name rather than an import.
    val jvmTargetEnum = runCatching {
        Class.forName("org.jetbrains.kotlin.gradle.dsl.JvmTarget")
            .enumConstants
            .first { (it as Enum<*>).name == "JVM_$jvmTarget" }
    }.getOrNull()

    if (jvmTargetEnum != null) {
        tasks.matching { it.javaClass.name.contains("KotlinCompile") }.configureEach {
            runCatching {
                val compilerOptions = javaClass.methods
                    .first { it.name == "getCompilerOptions" && it.parameterCount == 0 }
                    .invoke(this)
                val property = compilerOptions.javaClass.methods
                    .first { it.name == "getJvmTarget" && it.parameterCount == 0 }
                    .invoke(compilerOptions)
                @Suppress("UNCHECKED_CAST")
                (property as org.gradle.api.provider.Property<Any>).set(jvmTargetEnum)
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
