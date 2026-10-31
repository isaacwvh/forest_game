"""Deterministic, dependency-free Xcode project authoring; not needed to open/build.

Run after adding/removing Swift files. Assets stay at the repository root.
Only this project's generated pbxproj and shared schemes are written.
"""
from pathlib import Path
import hashlib
import json
import argparse

ROOT = Path(__file__).resolve().parents[1]


def identifier(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def serialize(value, indent=0):
    if isinstance(value, dict):
        lines = ["{"]
        for key, item in value.items():
            lines.append("\t" * (indent + 1) + f"{key} = {serialize(item, indent + 1)};")
        return "\n".join(lines) + "\n" + "\t" * indent + "}"
    if isinstance(value, list):
        return "(" + ", ".join(serialize(item, indent) for item in value) + ("," if value else "") + ")"
    if isinstance(value, int):
        return str(value)
    return json.dumps(value, ensure_ascii=False)


def generated_files():
    objects = {}

    def add(object_key, isa, **values):
        key = identifier(object_key)
        objects[key] = {"isa": isa, **values}
        return key

    def files(directory):
        result = []
        # Path ordering is case-insensitive on Windows and case-sensitive on
        # macOS/Linux. Sort the exact portable string to make generation identical.
        for path in sorted((ROOT / directory).rglob("*.swift"), key=lambda item: item.as_posix()):
            relative = path.relative_to(ROOT).as_posix()
            result.append(add(relative, "PBXFileReference", lastKnownFileType="sourcecode.swift", name=path.name,
                              path=relative, sourceTree="SOURCE_ROOT"))
        return result

    app_sources = files("MovementForest")
    unit_sources = files("MovementForestTests")
    ui_sources = files("MovementForestUITests")
    resource_refs = []
    asset_ids = json.loads((ROOT / "MovementForest/Resources/Fixtures/asset-index.json").read_text())
    for name, path in [(name, f"../assets/{name}") for name in asset_ids] + [
                       ("packs", "../assets/packs"), ("butterfly", "../assets/butterfly"),
                       ("png-128", "../assets/quantity-icons-v1/png-128"),
                       ("journal", "../assets/journal"),
                       ("Fixtures", "MovementForest/Resources/Fixtures")]:
        resource_refs.append(add("resource-" + name, "PBXFileReference", lastKnownFileType="folder",
                                 name=name, path=path, sourceTree="SOURCE_ROOT"))
    geometry_fixture = add("shared-placement-cases", "PBXFileReference", lastKnownFileType="text.json",
                           name="placement-cases.json", path="../spec_examples/placement-cases.json", sourceTree="SOURCE_ROOT")
    config_refs = [add("config-" + name, "PBXFileReference", lastKnownFileType=kind, name=name,
                       path="MovementForest/Configuration/" + name, sourceTree="SOURCE_ROOT")
                   for name, kind in [("Info.plist", "text.plist.xml"), ("MovementForest.entitlements", "text.plist.entitlements"),
                                      ("MovementForestApple.entitlements", "text.plist.entitlements"),
                                      ("Auth.xcconfig", "text.xcconfig"), ("Local.xcconfig.example", "text")]]
    auth_config = identifier("config-Auth.xcconfig")
    auth_package = add("supabase-package", "XCRemoteSwiftPackageReference",
                       repositoryURL="https://github.com/supabase/supabase-swift.git",
                       requirement={"kind": "exactVersion", "version": "2.55.4"})
    auth_product = add("supabase-auth-product", "XCSwiftPackageProductDependency", package=auth_package, productName="Auth")
    products = []
    targets = []
    for name, sources, product_type, extension in [
        ("MovementForest", app_sources, "application", "app"),
        ("MovementForestTests", unit_sources, "bundle.unit-test", "xctest"),
        ("MovementForestUITests", ui_sources, "bundle.ui-testing", "xctest"),
    ]:
        product = add("product-" + name, "PBXFileReference", explicitFileType="wrapper.application" if extension == "app" else "wrapper.cfbundle",
                      includeInIndex=0, path=name + "." + extension, sourceTree="BUILT_PRODUCTS_DIR")
        products.append(product)
        source_builds = [add("build-" + name + "-" + ref, "PBXBuildFile", fileRef=ref) for ref in sources]
        resources = [add("resource-build-" + ref, "PBXBuildFile", fileRef=ref) for ref in resource_refs] if name == "MovementForest" else []
        if name == "MovementForestTests":
            resources.append(add("test-shared-placement-cases", "PBXBuildFile", fileRef=geometry_fixture))
        frameworks = [add("supabase-auth-build", "PBXBuildFile", productRef=auth_product)] if name == "MovementForest" else []
        phases = [add("sources-" + name, "PBXSourcesBuildPhase", buildActionMask=2147483647, files=source_builds, runOnlyForDeploymentPostprocessing=0),
                  add("frameworks-" + name, "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=frameworks, runOnlyForDeploymentPostprocessing=0),
                  add("resources-" + name, "PBXResourcesBuildPhase", buildActionMask=2147483647, files=resources, runOnlyForDeploymentPostprocessing=0)]
        configs = []
        for mode in ["Debug", "Release", "InternalRelease"]:
            settings = {"PRODUCT_NAME": "$(TARGET_NAME)", "CODE_SIGN_STYLE": "Automatic",
                        "PRODUCT_BUNDLE_IDENTIFIER": "com.example.movementforest" + ("." + name if name != "MovementForest" else ""),
                        "TARGETED_DEVICE_FAMILY": "1", "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
                        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
                        "SWIFT_VERSION": "5.0"}
            if name == "MovementForest":
                settings.update({"INFOPLIST_FILE": "MovementForest/Configuration/Info.plist",
                                 "MARKETING_VERSION": "0.1.0", "CURRENT_PROJECT_VERSION": "1"})
            else:
                settings["GENERATE_INFOPLIST_FILE"] = "YES"
                if name == "MovementForestTests":
                    settings.update({"TEST_HOST": "$(BUILT_PRODUCTS_DIR)/MovementForest.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/MovementForest",
                                     "BUNDLE_LOADER": "$(TEST_HOST)"})
                else:
                    settings["TEST_TARGET_NAME"] = "MovementForest"
            config_values = {"buildSettings": settings, "name": mode}
            if name == "MovementForest":
                config_values["baseConfigurationReference"] = auth_config
            configs.append(add("configuration-" + name + mode, "XCBuildConfiguration", **config_values))
        config_list = add("configurations-" + name, "XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
        dependencies = []
        if name != "MovementForest":
            proxy = add("proxy-" + name, "PBXContainerItemProxy", containerPortal=identifier("project"), proxyType=1,
                        remoteGlobalIDString=identifier("target-MovementForest"), remoteInfo="MovementForest")
            dependencies = [add("dependency-" + name, "PBXTargetDependency", target=identifier("target-MovementForest"), targetProxy=proxy)]
        targets.append(add("target-" + name, "PBXNativeTarget", buildConfigurationList=config_list, buildPhases=phases,
                           buildRules=[], dependencies=dependencies, name=name, productName=name,
                           productReference=product, productType="com.apple.product-type." + product_type,
                           packageProductDependencies=[auth_product] if name == "MovementForest" else []))
    groups = [add("app-group", "PBXGroup", name="App", children=app_sources, sourceTree="<group>"),
              add("resources-group", "PBXGroup", name="Resources", children=resource_refs + config_refs, sourceTree="<group>"),
              add("unit-group", "PBXGroup", name="Unit tests", children=unit_sources + [geometry_fixture], sourceTree="<group>"),
              add("ui-group", "PBXGroup", name="UI tests", children=ui_sources, sourceTree="<group>"),
              add("products-group", "PBXGroup", name="Products", children=products, sourceTree="<group>")]
    main_group = add("main-group", "PBXGroup", children=groups, sourceTree="<group>")
    configs = []
    for mode in ["Debug", "Release", "InternalRelease"]:
        settings = {"SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "16.0", "CLANG_ENABLE_MODULES": "YES",
                    "CLANG_ENABLE_OBJC_ARC": "YES", "SWIFT_VERSION": "5.0", "SWIFT_STRICT_CONCURRENCY": "targeted",
                    "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu17",
                    "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O",
                    "DEBUG_INFORMATION_FORMAT": "dwarf" if mode == "Debug" else "dwarf-with-dsym"}
        if mode == "Debug":
            settings.update({"SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)", "ENABLE_TESTABILITY": "YES", "ONLY_ACTIVE_ARCH": "YES"})
        if mode == "InternalRelease":
            settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "INTERNAL_TOOLS $(inherited)"
        configs.append(add("project-configuration-" + mode, "XCBuildConfiguration", buildSettings=settings, name=mode))
    config_list = add("project-configurations", "XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1600",
        "TargetAttributes": {identifier("target-MovementForest"): {"CreatedOnToolsVersion": "16.0", "SystemCapabilities": {"com.apple.HealthKit": {"enabled": 1}}}}},
        buildConfigurationList=config_list, compatibilityVersion="Xcode 14.0", developmentRegion="en",
        hasScannedForEncodings=0, knownRegions=["en", "Base"], mainGroup=main_group,
        productRefGroup=identifier("products-group"), projectDirPath="", projectRoot="", targets=targets,
        packageReferences=[auth_package])
    project = "// !$*UTF8*$!\n" + serialize({"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": identifier("project")}) + "\n"

    def reference(name):
        ext = "app" if name == "MovementForest" else "xctest"
        return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier("target-" + name)}" BuildableName="{name}.{ext}" BlueprintName="{name}" ReferencedContainer="container:MovementForest.xcodeproj"/>'

    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference("MovementForest")}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO">
    <EnvironmentVariables><EnvironmentVariable key="FOREST_DISABLE_AUTH" value="1" isEnabled="YES"/></EnvironmentVariables>
    <Testables><TestableReference skipped="NO">{reference("MovementForestTests")}</TestableReference><TestableReference skipped="NO">{reference("MovementForestUITests")}</TestableReference></Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{reference("MovementForest")}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference("MovementForest")}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    return {"MovementForest.xcodeproj/project.pbxproj": project,
            "MovementForest.xcodeproj/xcshareddata/xcschemes/MovementForest.xcscheme": scheme,
            "MovementForest.xcodeproj/xcshareddata/xcschemes/MovementForest-Internal.xcscheme":
                scheme.replace('buildConfiguration="Release"', 'buildConfiguration="InternalRelease"').replace(
                    '<LaunchAction buildConfiguration="Debug"', '<LaunchAction buildConfiguration="InternalRelease"')}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    failures = []
    for relative, contents in generated_files().items():
        path = ROOT / relative
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != contents:
                failures.append(relative)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents, encoding="utf-8", newline="\n")
    if failures:
        raise SystemExit("Generated project is stale: " + ", ".join(failures))
    print("Xcode project is current." if args.check else "Wrote Xcode project and shared scheme.")


if __name__ == "__main__":
    main()
