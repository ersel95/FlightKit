#!/usr/bin/env python3
"""Generate Xcode project files for FlightKit (macOS SwiftUI app).
Single-target app with sources, resources, entitlements.
"""
from pathlib import Path

ROOT = Path(__file__).parent
PROJECT_DIR = ROOT / "FlightKit.xcodeproj"
APP_NAME = "FlightKit"            # internal target/scheme name
DISPLAY_NAME = "FlightKit"        # user-facing app name (Finder, menu bar, .app file)
APP_FILE = "FlightKitApp.swift"   # @main entry source
BUNDLE_ID = "com.flightkit.app"
TEAM_ID = ""  # users will sign locally

# Sparkle (auto-update) is the project's one external dependency, pulled via SPM.
# Its framework is embedded + signed by the release pipeline (see release-dmg.sh).
SPARKLE_REPO = "https://github.com/sparkle-project/Sparkle"
SPARKLE_MIN_VERSION = "2.9.0"
INFO_PLIST = "Info.plist"  # custom keys (Sparkle SUFeedURL/SUPublicEDKey) live here

SOURCES = [
    (APP_FILE, ""),
    ("Models/AppProject.swift", "Models"),
    ("Models/DistributionTarget.swift", "Models"),
    ("Models/ASCCredentials.swift", "Models"),
    ("Models/BuildVersionInfo.swift", "Models"),
    ("Models/ASCBuild.swift", "Models"),
    ("Models/PublishStep.swift", "Models"),
    ("Models/PipelineState.swift", "Models"),
    ("Models/PublishError.swift", "Models"),
    ("Models/HealRule.swift", "Models"),
    ("Models/AppSettings.swift", "Models"),
    ("Services/KeychainStore.swift", "Services"),
    ("Services/JWTGenerator.swift", "Services"),
    ("Services/ASCAPIClient.swift", "Services"),
    ("Services/XcconfigEditor.swift", "Services"),
    ("Services/XcodebuildRunner.swift", "Services"),
    ("Services/ExportOptionsBuilder.swift", "Services"),
    ("Services/AltoolUploader.swift", "Services"),
    ("Services/SelfHealer.swift", "Services"),
    ("Services/PublishOrchestrator.swift", "Services"),
    ("Services/ProjectStore.swift", "Services"),
    ("Services/ProjectInspector.swift", "Services"),
    ("Views/ContentView.swift", "Views"),
    ("Views/ProjectListView.swift", "Views"),
    ("Views/ProjectEditorView.swift", "Views"),
    ("Views/ProjectDetailView.swift", "Views"),
    ("Views/CredentialsEditor.swift", "Views"),
    ("Views/PipelineView.swift", "Views"),
    ("Views/UpdaterView.swift", "Views"),
    ("Views/SettingsView.swift", "Views"),
]
RESOURCES = [
    ("Resources/Assets.xcassets", "Resources", "folder.assetcatalog"),
]
ENTITLEMENTS = "FlightKit.entitlements"


def uid(prefix: str, n: int) -> str:
    return f"{prefix}{n:022X}"


def main():
    # Allocate UUIDs
    proj_uid = uid("F0", 1)
    main_group = uid("F1", 1)
    app_group = uid("F1", 2)
    products_group = uid("F1", 3)
    models_group = uid("F1", 4)
    services_group = uid("F1", 5)
    views_group = uid("F1", 6)
    resources_group = uid("F1", 7)

    target_uid = uid("F2", 1)
    sources_phase = uid("F3", 1)
    resources_phase = uid("F3", 2)
    frameworks_phase = uid("F3", 3)

    proj_cfg_list = uid("F4", 1)
    target_cfg_list = uid("F4", 2)
    proj_debug = uid("F4", 3)
    proj_release = uid("F4", 4)
    target_debug = uid("F4", 5)
    target_release = uid("F4", 6)

    product_ref = uid("F5", 1)
    entitlements_ref = uid("F5", 2)
    info_plist_ref = uid("F5", 3)

    # Sparkle SPM dependency objects.
    sparkle_pkg_ref = uid("F6", 1)   # XCRemoteSwiftPackageReference
    sparkle_prod_dep = uid("F6", 2)  # XCSwiftPackageProductDependency
    sparkle_build_file = uid("F6", 3)  # PBXBuildFile (Sparkle in Frameworks)

    # File refs and build files
    file_refs = {}      # path -> uid
    build_files = {}    # path -> uid
    counter = 100
    for path, _ in SOURCES + [(p, g) for p, g, _ in RESOURCES]:
        file_refs[path] = uid("A0", counter)
        build_files[path] = uid("B0", counter)
        counter += 1

    # Group children mapping
    group_map = {
        "Models": models_group,
        "Services": services_group,
        "Views": views_group,
        "Resources": resources_group,
    }

    out = []
    out.append("// !$*UTF8*$!")
    out.append("{")
    out.append("\tarchiveVersion = 1;")
    out.append("\tclasses = {")
    out.append("\t};")
    out.append("\tobjectVersion = 56;")
    out.append("\tobjects = {")

    # PBXBuildFile
    out.append("")
    out.append("/* Begin PBXBuildFile section */")
    for path, _ in SOURCES:
        name = Path(path).name
        out.append(f"\t\t{build_files[path]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[path]} /* {name} */; }};")
    for path, _, _ in RESOURCES:
        name = Path(path).name
        out.append(f"\t\t{build_files[path]} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {file_refs[path]} /* {name} */; }};")
    out.append(f"\t\t{sparkle_build_file} /* Sparkle in Frameworks */ = {{isa = PBXBuildFile; productRef = {sparkle_prod_dep} /* Sparkle */; }};")
    out.append("/* End PBXBuildFile section */")

    # PBXFileReference
    out.append("")
    out.append("/* Begin PBXFileReference section */")
    out.append(f'\t\t{product_ref} /* {DISPLAY_NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "{DISPLAY_NAME}.app"; sourceTree = BUILT_PRODUCTS_DIR; }};')
    out.append(f'\t\t{entitlements_ref} /* {ENTITLEMENTS} */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = {ENTITLEMENTS}; sourceTree = "<group>"; }};')
    out.append(f'\t\t{info_plist_ref} /* {INFO_PLIST} */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = {INFO_PLIST}; sourceTree = "<group>"; }};')
    for path, _ in SOURCES:
        name = Path(path).name
        out.append(f'\t\t{file_refs[path]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};')
    for path, _, ftype in RESOURCES:
        name = Path(path).name
        out.append(f'\t\t{file_refs[path]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = {name}; sourceTree = "<group>"; }};')
    out.append("/* End PBXFileReference section */")

    # PBXFrameworksBuildPhase
    out.append("")
    out.append("/* Begin PBXFrameworksBuildPhase section */")
    out.append(f"\t\t{frameworks_phase} /* Frameworks */ = {{")
    out.append("\t\t\tisa = PBXFrameworksBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    out.append(f"\t\t\t\t{sparkle_build_file} /* Sparkle in Frameworks */,")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXFrameworksBuildPhase section */")

    # PBXGroup
    out.append("")
    out.append("/* Begin PBXGroup section */")
    # main group
    out.append(f"\t\t{main_group} = {{")
    out.append("\t\t\tisa = PBXGroup;")
    out.append("\t\t\tchildren = (")
    out.append(f"\t\t\t\t{app_group} /* {APP_NAME} */,")
    out.append(f"\t\t\t\t{products_group} /* Products */,")
    out.append("\t\t\t);")
    out.append("\t\t\tsourceTree = \"<group>\";")
    out.append("\t\t};")
    # products group
    out.append(f"\t\t{products_group} /* Products */ = {{")
    out.append("\t\t\tisa = PBXGroup;")
    out.append("\t\t\tchildren = (")
    out.append(f"\t\t\t\t{product_ref} /* {DISPLAY_NAME}.app */,")
    out.append("\t\t\t);")
    out.append("\t\t\tname = Products;")
    out.append("\t\t\tsourceTree = \"<group>\";")
    out.append("\t\t};")
    # NLPublisher group (root of source files) -> contains sub groups + entitlements + NLPublisherApp.swift
    out.append(f"\t\t{app_group} /* {APP_NAME} */ = {{")
    out.append("\t\t\tisa = PBXGroup;")
    out.append("\t\t\tchildren = (")
    # App entry source first
    app_root = file_refs[APP_FILE]
    out.append(f"\t\t\t\t{app_root} /* {APP_FILE} */,")
    # subgroups
    out.append(f"\t\t\t\t{models_group} /* Models */,")
    out.append(f"\t\t\t\t{services_group} /* Services */,")
    out.append(f"\t\t\t\t{views_group} /* Views */,")
    out.append(f"\t\t\t\t{resources_group} /* Resources */,")
    out.append(f"\t\t\t\t{entitlements_ref} /* {ENTITLEMENTS} */,")
    out.append(f"\t\t\t\t{info_plist_ref} /* {INFO_PLIST} */,")
    out.append("\t\t\t);")
    out.append(f"\t\t\tpath = {APP_NAME};")
    out.append("\t\t\tsourceTree = \"<group>\";")
    out.append("\t\t};")
    # Models / Services / Views groups
    for group_name in ["Models", "Services", "Views"]:
        group_uid = group_map[group_name]
        out.append(f"\t\t{group_uid} /* {group_name} */ = {{")
        out.append("\t\t\tisa = PBXGroup;")
        out.append("\t\t\tchildren = (")
        for path, grp in SOURCES:
            if grp == group_name:
                name = Path(path).name
                out.append(f"\t\t\t\t{file_refs[path]} /* {name} */,")
        out.append("\t\t\t);")
        out.append(f"\t\t\tpath = {group_name};")
        out.append("\t\t\tsourceTree = \"<group>\";")
        out.append("\t\t};")
    # Resources group
    out.append(f"\t\t{resources_group} /* Resources */ = {{")
    out.append("\t\t\tisa = PBXGroup;")
    out.append("\t\t\tchildren = (")
    for path, _, _ in RESOURCES:
        name = Path(path).name
        out.append(f"\t\t\t\t{file_refs[path]} /* {name} */,")
    out.append("\t\t\t);")
    out.append("\t\t\tpath = Resources;")
    out.append("\t\t\tsourceTree = \"<group>\";")
    out.append("\t\t};")
    out.append("/* End PBXGroup section */")

    # PBXNativeTarget
    out.append("")
    out.append("/* Begin PBXNativeTarget section */")
    out.append(f"\t\t{target_uid} /* {APP_NAME} */ = {{")
    out.append("\t\t\tisa = PBXNativeTarget;")
    out.append(f"\t\t\tbuildConfigurationList = {target_cfg_list} /* Build configuration list for PBXNativeTarget \"{APP_NAME}\" */;")
    out.append("\t\t\tbuildPhases = (")
    out.append(f"\t\t\t\t{sources_phase} /* Sources */,")
    out.append(f"\t\t\t\t{frameworks_phase} /* Frameworks */,")
    out.append(f"\t\t\t\t{resources_phase} /* Resources */,")
    out.append("\t\t\t);")
    out.append("\t\t\tbuildRules = (")
    out.append("\t\t\t);")
    out.append("\t\t\tdependencies = (")
    out.append("\t\t\t);")
    out.append(f"\t\t\tname = {APP_NAME};")
    out.append("\t\t\tpackageProductDependencies = (")
    out.append(f"\t\t\t\t{sparkle_prod_dep} /* Sparkle */,")
    out.append("\t\t\t);")
    out.append(f"\t\t\tproductName = {APP_NAME};")
    out.append(f"\t\t\tproductReference = {product_ref} /* {DISPLAY_NAME}.app */;")
    out.append("\t\t\tproductType = \"com.apple.product-type.application\";")
    out.append("\t\t};")
    out.append("/* End PBXNativeTarget section */")

    # PBXProject
    out.append("")
    out.append("/* Begin PBXProject section */")
    out.append(f"\t\t{proj_uid} /* Project object */ = {{")
    out.append("\t\t\tisa = PBXProject;")
    out.append("\t\t\tattributes = {")
    out.append("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    out.append("\t\t\t\tLastSwiftUpdateCheck = 1500;")
    out.append("\t\t\t\tLastUpgradeCheck = 1500;")
    out.append("\t\t\t\tTargetAttributes = {")
    out.append(f"\t\t\t\t\t{target_uid} = {{")
    out.append("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
    out.append("\t\t\t\t\t};")
    out.append("\t\t\t\t};")
    out.append("\t\t\t};")
    out.append(f"\t\t\tbuildConfigurationList = {proj_cfg_list} /* Build configuration list for PBXProject \"{APP_NAME}\" */;")
    out.append("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    out.append("\t\t\tdevelopmentRegion = en;")
    out.append("\t\t\thasScannedForEncodings = 0;")
    out.append("\t\t\tknownRegions = (")
    out.append("\t\t\t\ten,")
    out.append("\t\t\t\tBase,")
    out.append("\t\t\t);")
    out.append(f"\t\t\tmainGroup = {main_group};")
    out.append("\t\t\tpackageReferences = (")
    out.append(f"\t\t\t\t{sparkle_pkg_ref} /* XCRemoteSwiftPackageReference \"Sparkle\" */,")
    out.append("\t\t\t);")
    out.append(f"\t\t\tproductRefGroup = {products_group} /* Products */;")
    out.append("\t\t\tprojectDirPath = \"\";")
    out.append("\t\t\tprojectRoot = \"\";")
    out.append("\t\t\ttargets = (")
    out.append(f"\t\t\t\t{target_uid} /* {APP_NAME} */,")
    out.append("\t\t\t);")
    out.append("\t\t};")
    out.append("/* End PBXProject section */")

    # PBXResourcesBuildPhase
    out.append("")
    out.append("/* Begin PBXResourcesBuildPhase section */")
    out.append(f"\t\t{resources_phase} /* Resources */ = {{")
    out.append("\t\t\tisa = PBXResourcesBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    for path, _, _ in RESOURCES:
        name = Path(path).name
        out.append(f"\t\t\t\t{build_files[path]} /* {name} in Resources */,")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXResourcesBuildPhase section */")

    # PBXSourcesBuildPhase
    out.append("")
    out.append("/* Begin PBXSourcesBuildPhase section */")
    out.append(f"\t\t{sources_phase} /* Sources */ = {{")
    out.append("\t\t\tisa = PBXSourcesBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    for path, _ in SOURCES:
        name = Path(path).name
        out.append(f"\t\t\t\t{build_files[path]} /* {name} in Sources */,")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXSourcesBuildPhase section */")

    # XCBuildConfiguration (project)
    common_proj_settings = [
        "ALWAYS_SEARCH_USER_PATHS = NO;",
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;",
        "CLANG_ANALYZER_NONNULL = YES;",
        "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;",
        "CLANG_CXX_LANGUAGE_STANDARD = \"gnu++20\";",
        "CLANG_ENABLE_MODULES = YES;",
        "CLANG_ENABLE_OBJC_ARC = YES;",
        "CLANG_ENABLE_OBJC_WEAK = YES;",
        "COPY_PHASE_STRIP = NO;",
        "DEAD_CODE_STRIPPING = YES;",
        "ENABLE_STRICT_OBJC_MSGSEND = YES;",
        "ENABLE_USER_SCRIPT_SANDBOXING = YES;",
        "GCC_C_LANGUAGE_STANDARD = gnu17;",
        "GCC_NO_COMMON_BLOCKS = YES;",
        "MACOSX_DEPLOYMENT_TARGET = 14.0;",
        "MTL_FAST_MATH = YES;",
        "SDKROOT = macosx;",
        "SWIFT_VERSION = 5.0;",
    ]
    out.append("")
    out.append("/* Begin XCBuildConfiguration section */")
    # project debug
    out.append(f"\t\t{proj_debug} /* Debug */ = {{")
    out.append("\t\t\tisa = XCBuildConfiguration;")
    out.append("\t\t\tbuildSettings = {")
    for s in common_proj_settings:
        out.append(f"\t\t\t\t{s}")
    out.append("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
    out.append("\t\t\t\tENABLE_TESTABILITY = YES;")
    out.append("\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;")
    out.append("\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;")
    out.append("\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (")
    out.append("\t\t\t\t\t\"DEBUG=1\",")
    out.append("\t\t\t\t\t\"$(inherited)\",")
    out.append("\t\t\t\t);")
    out.append("\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;")
    out.append("\t\t\t\tONLY_ACTIVE_ARCH = YES;")
    out.append("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = \"DEBUG $(inherited)\";")
    out.append("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";")
    out.append("\t\t\t};")
    out.append("\t\t\tname = Debug;")
    out.append("\t\t};")
    # project release
    out.append(f"\t\t{proj_release} /* Release */ = {{")
    out.append("\t\t\tisa = XCBuildConfiguration;")
    out.append("\t\t\tbuildSettings = {")
    for s in common_proj_settings:
        out.append(f"\t\t\t\t{s}")
    out.append("\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";")
    out.append("\t\t\t\tENABLE_NS_ASSERTIONS = NO;")
    out.append("\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;")
    out.append("\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;")
    out.append("\t\t\t};")
    out.append("\t\t\tname = Release;")
    out.append("\t\t};")
    # target debug + release share most settings
    target_settings = [
        "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;",
        f"CODE_SIGN_ENTITLEMENTS = {APP_NAME}/{ENTITLEMENTS};",
        "CODE_SIGN_STYLE = Automatic;",
        "COMBINE_HIDPI_IMAGES = YES;",
        "CURRENT_PROJECT_VERSION = 1;",
        "ENABLE_HARDENED_RUNTIME = YES;",
        "ENABLE_PREVIEWS = YES;",
        "GENERATE_INFOPLIST_FILE = YES;",
        # Custom Info.plist holds the Sparkle keys; GENERATE_INFOPLIST_FILE still
        # merges the synthesized + INFOPLIST_KEY_* values on top of it.
        f"INFOPLIST_FILE = {APP_NAME}/{INFO_PLIST};",
        # Required so the loader finds the embedded Sparkle.framework at runtime.
        # Xcode's app template sets this implicitly; our generated project must too.
        "LD_RUNPATH_SEARCH_PATHS = \"$(inherited) @executable_path/../Frameworks\";",
        f"INFOPLIST_KEY_CFBundleDisplayName = \"{DISPLAY_NAME}\";",
        f"INFOPLIST_KEY_CFBundleName = \"{DISPLAY_NAME}\";",
        "INFOPLIST_KEY_LSApplicationCategoryType = \"public.app-category.developer-tools\";",
        "INFOPLIST_KEY_NSHumanReadableCopyright = \"Created by Mr. t.\";",
        f"INFOPLIST_KEY_NSPrincipalClass = NSApplication;",
        "MARKETING_VERSION = 1.0;",
        f"PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};",
        f"PRODUCT_NAME = \"{DISPLAY_NAME}\";",
        "SWIFT_EMIT_LOC_STRINGS = YES;",
        "SWIFT_VERSION = 5.0;",
    ]
    for cfg_uid, cfg_name in [(target_debug, "Debug"), (target_release, "Release")]:
        out.append(f"\t\t{cfg_uid} /* {cfg_name} */ = {{")
        out.append("\t\t\tisa = XCBuildConfiguration;")
        out.append("\t\t\tbuildSettings = {")
        for s in target_settings:
            out.append(f"\t\t\t\t{s}")
        out.append("\t\t\t};")
        out.append(f"\t\t\tname = {cfg_name};")
        out.append("\t\t};")
    out.append("/* End XCBuildConfiguration section */")

    # XCConfigurationList
    out.append("")
    out.append("/* Begin XCConfigurationList section */")
    out.append(f"\t\t{proj_cfg_list} /* Build configuration list for PBXProject \"{APP_NAME}\" */ = {{")
    out.append("\t\t\tisa = XCConfigurationList;")
    out.append("\t\t\tbuildConfigurations = (")
    out.append(f"\t\t\t\t{proj_debug} /* Debug */,")
    out.append(f"\t\t\t\t{proj_release} /* Release */,")
    out.append("\t\t\t);")
    out.append("\t\t\tdefaultConfigurationIsVisible = 0;")
    out.append("\t\t\tdefaultConfigurationName = Release;")
    out.append("\t\t};")
    out.append(f"\t\t{target_cfg_list} /* Build configuration list for PBXNativeTarget \"{APP_NAME}\" */ = {{")
    out.append("\t\t\tisa = XCConfigurationList;")
    out.append("\t\t\tbuildConfigurations = (")
    out.append(f"\t\t\t\t{target_debug} /* Debug */,")
    out.append(f"\t\t\t\t{target_release} /* Release */,")
    out.append("\t\t\t);")
    out.append("\t\t\tdefaultConfigurationIsVisible = 0;")
    out.append("\t\t\tdefaultConfigurationName = Release;")
    out.append("\t\t};")
    out.append("/* End XCConfigurationList section */")

    # XCRemoteSwiftPackageReference (Sparkle)
    out.append("")
    out.append("/* Begin XCRemoteSwiftPackageReference section */")
    out.append(f'\t\t{sparkle_pkg_ref} /* XCRemoteSwiftPackageReference "Sparkle" */ = {{')
    out.append("\t\t\tisa = XCRemoteSwiftPackageReference;")
    out.append(f'\t\t\trepositoryURL = "{SPARKLE_REPO}";')
    out.append("\t\t\trequirement = {")
    out.append("\t\t\t\tkind = upToNextMajorVersion;")
    out.append(f"\t\t\t\tminimumVersion = {SPARKLE_MIN_VERSION};")
    out.append("\t\t\t};")
    out.append("\t\t};")
    out.append("/* End XCRemoteSwiftPackageReference section */")

    # XCSwiftPackageProductDependency (Sparkle)
    out.append("")
    out.append("/* Begin XCSwiftPackageProductDependency section */")
    out.append(f"\t\t{sparkle_prod_dep} /* Sparkle */ = {{")
    out.append("\t\t\tisa = XCSwiftPackageProductDependency;")
    out.append(f'\t\t\tpackage = {sparkle_pkg_ref} /* XCRemoteSwiftPackageReference "Sparkle" */;')
    out.append("\t\t\tproductName = Sparkle;")
    out.append("\t\t};")
    out.append("/* End XCSwiftPackageProductDependency section */")

    out.append("\t};")
    out.append(f"\trootObject = {proj_uid} /* Project object */;")
    out.append("}")

    pbxproj_path = PROJECT_DIR / "project.pbxproj"
    pbxproj_path.parent.mkdir(parents=True, exist_ok=True)
    pbxproj_path.write_text("\n".join(out) + "\n")

    # workspace
    ws_dir = PROJECT_DIR / "project.xcworkspace"
    ws_dir.mkdir(parents=True, exist_ok=True)
    (ws_dir / "contents.xcworkspacedata").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Workspace version="1.0">\n'
        '   <FileRef location="self:"></FileRef>\n'
        '</Workspace>\n'
    )

    # shared scheme
    schemes_dir = PROJECT_DIR / "xcshareddata" / "xcschemes"
    schemes_dir.mkdir(parents=True, exist_ok=True)
    scheme_xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1500" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_uid}" BuildableName="{DISPLAY_NAME}.app" BlueprintName="{APP_NAME}" ReferencedContainer="container:{APP_NAME}.xcodeproj"></BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"></TestAction>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_uid}" BuildableName="{DISPLAY_NAME}.app" BlueprintName="{APP_NAME}" ReferencedContainer="container:{APP_NAME}.xcodeproj"></BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_uid}" BuildableName="{DISPLAY_NAME}.app" BlueprintName="{APP_NAME}" ReferencedContainer="container:{APP_NAME}.xcodeproj"></BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"></ArchiveAction>
</Scheme>
'''
    (schemes_dir / f"{APP_NAME}.xcscheme").write_text(scheme_xml)
    print(f"Wrote {pbxproj_path}")


if __name__ == "__main__":
    main()
