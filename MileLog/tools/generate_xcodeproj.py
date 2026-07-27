#!/usr/bin/env python3
"""
Regenerates MileLog.xcodeproj from the source tree.

The project file is checked in, so you normally don't need this — it exists so
the project can be rebuilt deterministically after adding/removing source
files, rather than being a hand-edited artifact nobody dares touch.

    python3 tools/generate_xcodeproj.py

Object IDs are derived from a stable hash of each object's role, so re-running
this on an unchanged tree produces a byte-identical file (no spurious diffs).
"""

import hashlib
import os
import plistlib
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(ROOT, "MileLog")
PROJ_DIR = os.path.join(ROOT, "MileLog.xcodeproj")

APP_NAME = "MileLog"
BUNDLE_ID = "com.blisk.milelog"
DEPLOYMENT_TARGET = "17.0"
SWIFT_VERSION = "5.0"
SUPABASE_REPO = "https://github.com/supabase/supabase-swift"
SUPABASE_MIN_VERSION = "2.0.0"

# ---------------------------------------------------------------- object IDs


def oid(role: str) -> str:
    """Deterministic 24-char uppercase hex ID, unique per role string."""
    return hashlib.sha1(role.encode()).hexdigest()[:24].upper()


# ---------------------------------------------------------------- discovery


def discover():
    """Swift sources (compiled) and resources (bundled), relative to SRC_DIR."""
    sources, resources = [], []
    for dirpath, dirnames, filenames in os.walk(SRC_DIR):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for fn in sorted(filenames):
            rel = os.path.relpath(os.path.join(dirpath, fn), SRC_DIR)
            if fn.endswith(".swift"):
                sources.append(rel)
            elif fn.endswith((".xcstrings", ".xcassets")):
                resources.append(rel)
    return sources, resources


# ---------------------------------------------------------------- Info.plist


def write_info_plist():
    """
    An explicit Info.plist rather than GENERATE_INFOPLIST_FILE, because this
    app needs a fair number of custom keys (Supabase credentials, five privacy
    strings, a URL scheme and a background mode) and having them in one
    readable file beats scattering them across build settings.
    """
    plist = {
        "CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "$(PRODUCT_NAME)",
        "CFBundlePackageType": "$(PRODUCT_BUNDLE_PACKAGE_TYPE)",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "LSRequiresIPhoneOS": True,
        "UILaunchScreen": {},
        "UISupportedInterfaceOrientations": [
            "UIInterfaceOrientationPortrait",
        ],
        # --- Supabase credentials -------------------------------------
        # Placeholders. Fill these in locally and DO NOT commit real values.
        "SUPABASE_URL": "$(SUPABASE_URL)",
        "SUPABASE_ANON_KEY": "$(SUPABASE_ANON_KEY)",
        # --- Background execution -------------------------------------
        # Required: both TripDetector and LocationManager set
        # allowsBackgroundLocationUpdates, which traps at runtime without it.
        "UIBackgroundModes": ["location"],
        # --- Privacy usage descriptions -------------------------------
        "NSLocationWhenInUseUsageDescription":
            "MileLog measures the distance of your trips.",
        "NSLocationAlwaysAndWhenInUseUsageDescription":
            "MileLog records trips in the background so you do not have to "
            "start them manually.",
        "NSCameraUsageDescription":
            "Take a photo of a receipt to attach it to a trip.",
        "NSPhotoLibraryUsageDescription":
            "Attach an existing receipt photo to a trip.",
        "NSMotionUsageDescription":
            "Confirms that you are actually driving, so trips are not started "
            "by walking.",
        # --- Password-reset deep link ---------------------------------
        # Must match SupabaseConfig.passwordResetRedirect, and must also be
        # allow-listed in Supabase → Authentication → URL Configuration.
        "CFBundleURLTypes": [
            {
                "CFBundleTypeRole": "Editor",
                "CFBundleURLName": BUNDLE_ID,
                "CFBundleURLSchemes": ["milelog"],
            }
        ],
    }
    path = os.path.join(SRC_DIR, "Info.plist")
    with open(path, "wb") as f:
        plistlib.dump(plist, f, sort_keys=True)
    return "Info.plist"


# ---------------------------------------------------------------- assets


def write_asset_catalog():
    """Minimal catalog so Xcode has an AppIcon/AccentColor slot to fill."""
    cat = os.path.join(SRC_DIR, "Assets.xcassets")
    os.makedirs(os.path.join(cat, "AppIcon.appiconset"), exist_ok=True)
    os.makedirs(os.path.join(cat, "AccentColor.colorset"), exist_ok=True)

    def dump(rel, body):
        with open(os.path.join(cat, rel), "w") as f:
            f.write(body)

    root_meta = '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n'
    dump("Contents.json", root_meta)
    dump(
        "AppIcon.appiconset/Contents.json",
        '{\n'
        '  "images" : [\n'
        '    {\n'
        '      "idiom" : "universal",\n'
        '      "platform" : "ios",\n'
        '      "size" : "1024x1024"\n'
        '    }\n'
        '  ],\n'
        '  "info" : {\n'
        '    "author" : "xcode",\n'
        '    "version" : 1\n'
        '  }\n'
        '}\n',
    )
    dump(
        "AccentColor.colorset/Contents.json",
        '{\n'
        '  "colors" : [\n'
        '    {\n'
        '      "color" : {\n'
        '        "color-space" : "srgb",\n'
        '        "components" : {\n'
        '          "alpha" : "1.000",\n'
        '          "blue" : "0.851",\n'
        '          "green" : "0.494",\n'
        '          "red" : "0.290"\n'
        '        }\n'
        '      },\n'
        '      "idiom" : "universal"\n'
        '    }\n'
        '  ],\n'
        '  "info" : {\n'
        '    "author" : "xcode",\n'
        '    "version" : 1\n'
        '  }\n'
        '}\n',
    )
    return "Assets.xcassets"


# ---------------------------------------------------------------- pbxproj


def build_pbxproj(sources, resources):
    L = []
    add = L.append

    # ---- ids
    proj_id = oid("project")
    target_id = oid("target")
    product_id = oid("product")
    main_group = oid("group.main")
    src_group = oid("group.src")
    views_group = oid("group.views")
    products_group = oid("group.products")
    frameworks_group = oid("group.frameworks")
    sources_phase = oid("phase.sources")
    frameworks_phase = oid("phase.frameworks")
    resources_phase = oid("phase.resources")
    pkg_ref = oid("pkg.supabase")
    pkg_product = oid("pkg.supabase.product")
    pkg_buildfile = oid("pkg.supabase.buildfile")
    proj_cfg_list = oid("cfglist.project")
    tgt_cfg_list = oid("cfglist.target")
    proj_debug = oid("cfg.project.debug")
    proj_release = oid("cfg.project.release")
    tgt_debug = oid("cfg.target.debug")
    tgt_release = oid("cfg.target.release")

    root_files = [f for f in sources if "/" not in f]
    view_files = [f for f in sources if f.startswith("Views/")]

    add("// !$*UTF8*$!")
    add("{")
    add("\tarchiveVersion = 1;")
    add("\tclasses = {\n\t};")
    add("\tobjectVersion = 56;")
    add("\tobjects = {")

    # ---- PBXBuildFile
    add("\n/* Begin PBXBuildFile section */")
    for rel in sources:
        add(f"\t\t{oid('bf.'+rel)} /* {os.path.basename(rel)} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {oid('fr.'+rel)} /* {os.path.basename(rel)} */; }};")
    for rel in resources:
        add(f"\t\t{oid('bf.'+rel)} /* {os.path.basename(rel)} in Resources */ = "
            f"{{isa = PBXBuildFile; fileRef = {oid('fr.'+rel)} /* {os.path.basename(rel)} */; }};")
    add(f"\t\t{pkg_buildfile} /* Supabase in Frameworks */ = "
        f"{{isa = PBXBuildFile; productRef = {pkg_product} /* Supabase */; }};")
    add("/* End PBXBuildFile section */")

    # ---- PBXFileReference
    add("\n/* Begin PBXFileReference section */")
    add(f"\t\t{product_id} /* {APP_NAME}.app */ = {{isa = PBXFileReference; "
        f"explicitFileType = wrapper.application; includeInIndex = 0; "
        f"path = {APP_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
    for rel in sources:
        base = os.path.basename(rel)
        add(f"\t\t{oid('fr.'+rel)} /* {base} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; path = {base}; sourceTree = \"<group>\"; }};")
    for rel in resources:
        base = os.path.basename(rel)
        ftype = ("folder.assetcatalog" if base.endswith(".xcassets")
                 else "text.json.xcstrings")
        add(f"\t\t{oid('fr.'+rel)} /* {base} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = {ftype}; path = {base}; sourceTree = \"<group>\"; }};")
    add(f"\t\t{oid('fr.Info.plist')} /* Info.plist */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};")
    add("/* End PBXFileReference section */")

    # ---- PBXFrameworksBuildPhase
    add("\n/* Begin PBXFrameworksBuildPhase section */")
    add(f"\t\t{frameworks_phase} /* Frameworks */ = {{")
    add("\t\t\tisa = PBXFrameworksBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    add(f"\t\t\t\t{pkg_buildfile} /* Supabase in Frameworks */,")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXFrameworksBuildPhase section */")

    # ---- PBXGroup
    add("\n/* Begin PBXGroup section */")
    add(f"\t\t{main_group} = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    add(f"\t\t\t\t{src_group} /* {APP_NAME} */,")
    add(f"\t\t\t\t{frameworks_group} /* Frameworks */,")
    add(f"\t\t\t\t{products_group} /* Products */,")
    add("\t\t\t);")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")

    add(f"\t\t{src_group} /* {APP_NAME} */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    for rel in root_files:
        add(f"\t\t\t\t{oid('fr.'+rel)} /* {os.path.basename(rel)} */,")
    add(f"\t\t\t\t{views_group} /* Views */,")
    for rel in resources:
        add(f"\t\t\t\t{oid('fr.'+rel)} /* {os.path.basename(rel)} */,")
    add(f"\t\t\t\t{oid('fr.Info.plist')} /* Info.plist */,")
    add("\t\t\t);")
    add(f"\t\t\tpath = {APP_NAME};")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")

    add(f"\t\t{views_group} /* Views */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    for rel in view_files:
        add(f"\t\t\t\t{oid('fr.'+rel)} /* {os.path.basename(rel)} */,")
    add("\t\t\t);")
    add("\t\t\tpath = Views;")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")

    add(f"\t\t{frameworks_group} /* Frameworks */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (\n\t\t\t);")
    add("\t\t\tname = Frameworks;")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")

    add(f"\t\t{products_group} /* Products */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    add(f"\t\t\t\t{product_id} /* {APP_NAME}.app */,")
    add("\t\t\t);")
    add("\t\t\tname = Products;")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")
    add("/* End PBXGroup section */")

    # ---- PBXNativeTarget
    add("\n/* Begin PBXNativeTarget section */")
    add(f"\t\t{target_id} /* {APP_NAME} */ = {{")
    add("\t\t\tisa = PBXNativeTarget;")
    add(f"\t\t\tbuildConfigurationList = {tgt_cfg_list};")
    add("\t\t\tbuildPhases = (")
    add(f"\t\t\t\t{sources_phase} /* Sources */,")
    add(f"\t\t\t\t{frameworks_phase} /* Frameworks */,")
    add(f"\t\t\t\t{resources_phase} /* Resources */,")
    add("\t\t\t);")
    add("\t\t\tbuildRules = (\n\t\t\t);")
    add("\t\t\tdependencies = (\n\t\t\t);")
    add(f"\t\t\tname = {APP_NAME};")
    add("\t\t\tpackageProductDependencies = (")
    add(f"\t\t\t\t{pkg_product} /* Supabase */,")
    add("\t\t\t);")
    add(f"\t\t\tproductName = {APP_NAME};")
    add(f"\t\t\tproductReference = {product_id} /* {APP_NAME}.app */;")
    add("\t\t\tproductType = \"com.apple.product-type.application\";")
    add("\t\t};")
    add("/* End PBXNativeTarget section */")

    # ---- PBXProject
    add("\n/* Begin PBXProject section */")
    add(f"\t\t{proj_id} /* Project object */ = {{")
    add("\t\t\tisa = PBXProject;")
    add("\t\t\tattributes = {")
    add("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    add("\t\t\t\tLastSwiftUpdateCheck = 1520;")
    add("\t\t\t\tLastUpgradeCheck = 1520;")
    add("\t\t\t\tTargetAttributes = {")
    add(f"\t\t\t\t\t{target_id} = {{")
    add("\t\t\t\t\t\tCreatedOnToolsVersion = 15.2;")
    add("\t\t\t\t\t};")
    add("\t\t\t\t};")
    add("\t\t\t};")
    add(f"\t\t\tbuildConfigurationList = {proj_cfg_list};")
    add("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    add("\t\t\tdevelopmentRegion = en;")
    add("\t\t\thasScannedForEncodings = 0;")
    add("\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t\tsl,\n\t\t\t);")
    add(f"\t\t\tmainGroup = {main_group};")
    add("\t\t\tpackageReferences = (")
    add(f"\t\t\t\t{pkg_ref} /* XCRemoteSwiftPackageReference \"supabase-swift\" */,")
    add("\t\t\t);")
    add(f"\t\t\tproductRefGroup = {products_group} /* Products */;")
    add("\t\t\tprojectDirPath = \"\";")
    add("\t\t\tprojectRoot = \"\";")
    add("\t\t\ttargets = (")
    add(f"\t\t\t\t{target_id} /* {APP_NAME} */,")
    add("\t\t\t);")
    add("\t\t};")
    add("/* End PBXProject section */")

    # ---- PBXResourcesBuildPhase
    add("\n/* Begin PBXResourcesBuildPhase section */")
    add(f"\t\t{resources_phase} /* Resources */ = {{")
    add("\t\t\tisa = PBXResourcesBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    for rel in resources:
        add(f"\t\t\t\t{oid('bf.'+rel)} /* {os.path.basename(rel)} in Resources */,")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXResourcesBuildPhase section */")

    # ---- PBXSourcesBuildPhase
    add("\n/* Begin PBXSourcesBuildPhase section */")
    add(f"\t\t{sources_phase} /* Sources */ = {{")
    add("\t\t\tisa = PBXSourcesBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    for rel in sources:
        add(f"\t\t\t\t{oid('bf.'+rel)} /* {os.path.basename(rel)} in Sources */,")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXSourcesBuildPhase section */")

    # ---- XCBuildConfiguration
    common = [
        "ALWAYS_SEARCH_USER_PATHS = NO;",
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;",
        "CLANG_ANALYZER_NONNULL = YES;",
        "CLANG_ENABLE_MODULES = YES;",
        "CLANG_ENABLE_OBJC_ARC = YES;",
        "COPY_PHASE_STRIP = NO;",
        "ENABLE_STRICT_OBJC_MSGSEND = YES;",
        "GCC_C_LANGUAGE_STANDARD = gnu17;",
        f"IPHONEOS_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};",
        "MTL_FAST_MATH = YES;",
        "SDKROOT = iphoneos;",
        # Minimal, not Complete: the CoreLocation delegates are `nonisolated`
        # and hop to the main actor by hand, which Complete flags heavily.
        # Tighten this once the project builds cleanly.
        "SWIFT_STRICT_CONCURRENCY = minimal;",
    ]
    add("\n/* Begin XCBuildConfiguration section */")

    for cfg_id, name, extra in [
        (proj_debug, "Debug", [
            "DEBUG_INFORMATION_FORMAT = dwarf;",
            "ENABLE_TESTABILITY = YES;",
            "GCC_OPTIMIZATION_LEVEL = 0;",
            "GCC_PREPROCESSOR_DEFINITIONS = (\"DEBUG=1\", \"$(inherited)\",);",
            "MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;",
            "ONLY_ACTIVE_ARCH = YES;",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS = \"DEBUG $(inherited)\";",
            "SWIFT_OPTIMIZATION_LEVEL = \"-Onone\";",
        ]),
        (proj_release, "Release", [
            "DEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";",
            "ENABLE_NS_ASSERTIONS = NO;",
            "MTL_ENABLE_DEBUG_INFO = NO;",
            "SWIFT_COMPILATION_MODE = wholemodule;",
            "VALIDATE_PRODUCT = YES;",
        ]),
    ]:
        add(f"\t\t{cfg_id} /* {name} */ = {{")
        add("\t\t\tisa = XCBuildConfiguration;")
        add("\t\t\tbuildSettings = {")
        for line in common + extra:
            add(f"\t\t\t\t{line}")
        add("\t\t\t};")
        add(f"\t\t\tname = {name};")
        add("\t\t};")

    target_common = [
        "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;",
        "CODE_SIGN_STYLE = Automatic;",
        "CURRENT_PROJECT_VERSION = 1;",
        "ENABLE_PREVIEWS = YES;",
        "GENERATE_INFOPLIST_FILE = NO;",
        f"INFOPLIST_FILE = {APP_NAME}/Info.plist;",
        "LD_RUNPATH_SEARCH_PATHS = (\"$(inherited)\", \"@executable_path/Frameworks\",);",
        "MARKETING_VERSION = 1.0;",
        f"PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};",
        "PRODUCT_NAME = \"$(TARGET_NAME)\";",
        "SWIFT_EMIT_LOC_STRINGS = YES;",
        f"SWIFT_VERSION = {SWIFT_VERSION};",
        "TARGETED_DEVICE_FAMILY = \"1,2\";",
    ]
    for cfg_id, name in [(tgt_debug, "Debug"), (tgt_release, "Release")]:
        add(f"\t\t{cfg_id} /* {name} */ = {{")
        add("\t\t\tisa = XCBuildConfiguration;")
        add("\t\t\tbuildSettings = {")
        for line in target_common:
            add(f"\t\t\t\t{line}")
        add("\t\t\t};")
        add(f"\t\t\tname = {name};")
        add("\t\t};")
    add("/* End XCBuildConfiguration section */")

    # ---- XCConfigurationList
    add("\n/* Begin XCConfigurationList section */")
    for list_id, label, dbg, rel_ in [
        (proj_cfg_list, f"PBXProject \"{APP_NAME}\"", proj_debug, proj_release),
        (tgt_cfg_list, f"PBXNativeTarget \"{APP_NAME}\"", tgt_debug, tgt_release),
    ]:
        add(f"\t\t{list_id} /* Build configuration list for {label} */ = {{")
        add("\t\t\tisa = XCConfigurationList;")
        add("\t\t\tbuildConfigurations = (")
        add(f"\t\t\t\t{dbg} /* Debug */,")
        add(f"\t\t\t\t{rel_} /* Release */,")
        add("\t\t\t);")
        add("\t\t\tdefaultConfigurationIsVisible = 0;")
        add("\t\t\tdefaultConfigurationName = Release;")
        add("\t\t};")
    add("/* End XCConfigurationList section */")

    # ---- Swift package
    add("\n/* Begin XCRemoteSwiftPackageReference section */")
    add(f"\t\t{pkg_ref} /* XCRemoteSwiftPackageReference \"supabase-swift\" */ = {{")
    add("\t\t\tisa = XCRemoteSwiftPackageReference;")
    add(f"\t\t\trepositoryURL = \"{SUPABASE_REPO}\";")
    add("\t\t\trequirement = {")
    add(f"\t\t\t\tkind = upToNextMajorVersion;")
    add(f"\t\t\t\tminimumVersion = {SUPABASE_MIN_VERSION};")
    add("\t\t\t};")
    add("\t\t};")
    add("/* End XCRemoteSwiftPackageReference section */")

    add("\n/* Begin XCSwiftPackageProductDependency section */")
    add(f"\t\t{pkg_product} /* Supabase */ = {{")
    add("\t\t\tisa = XCSwiftPackageProductDependency;")
    add(f"\t\t\tpackage = {pkg_ref} /* XCRemoteSwiftPackageReference \"supabase-swift\" */;")
    add("\t\t\tproductName = Supabase;")
    add("\t\t};")
    add("/* End XCSwiftPackageProductDependency section */")

    add("\t};")
    add(f"\trootObject = {proj_id} /* Project object */;")
    add("}")
    return "\n".join(L) + "\n"


def main():
    sources, resources = discover()
    # Info.plist is wired via INFOPLIST_FILE, so it is written but NOT added
    # to the Resources phase (doing both makes Xcode copy it twice).
    write_info_plist()
    resources.append(write_asset_catalog())
    resources = sorted(set(resources))

    os.makedirs(PROJ_DIR, exist_ok=True)
    with open(os.path.join(PROJ_DIR, "project.pbxproj"), "w") as f:
        f.write(build_pbxproj(sources, resources))

    ws = os.path.join(PROJ_DIR, "project.xcworkspace")
    os.makedirs(ws, exist_ok=True)
    with open(os.path.join(ws, "contents.xcworkspacedata"), "w") as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n'
                '<Workspace\n   version = "1.0">\n'
                '   <FileRef\n      location = "self:">\n   </FileRef>\n'
                '</Workspace>\n')

    print(f"Wrote {PROJ_DIR}")
    print(f"  {len(sources)} Swift sources -> Compile Sources")
    print(f"  {len(resources)} resources    -> Copy Bundle Resources")
    for r in resources:
        print(f"      {r}")


if __name__ == "__main__":
    main()
