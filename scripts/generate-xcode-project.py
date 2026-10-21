#!/usr/bin/env python3
"""Generate the native app project with a navigator matching the repository layout."""

import hashlib
import json
from collections import defaultdict
from pathlib import Path
from xml.etree import ElementTree


ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "Stampede.xcodeproj"
FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".icns": "image.icns",
    ".plist": "text.plist.xml",
    ".md": "net.daringfireball.markdown",
    ".py": "text.script.python",
    ".sh": "text.script.sh",
}


class Reference(str):
    """An unquoted reference to another project object."""


def serialize(value, depth=0):
    """Write readable OpenStep property lists with one field or item per line."""
    indent = "\t" * depth
    child_indent = indent + "\t"
    if isinstance(value, Reference):
        return str(value)
    if isinstance(value, dict):
        fields = [
            f"{child_indent}{key} = {serialize(item, depth + 1)};"
            for key, item in value.items()
        ]
        return "{\n" + "\n".join(fields) + f"\n{indent}}}"
    if isinstance(value, list):
        if not value:
            return "()"
        items = [f"{child_indent}{serialize(item, depth + 1)}," for item in value]
        return "(\n" + "\n".join(items) + f"\n{indent})"
    return json.dumps(value, ensure_ascii=False)


class Project:
    def __init__(self):
        self.sections = defaultdict(list)
        self.source_builds = []
        self.resource_builds = []

    def add(self, key, kind, **fields):
        identifier = Reference(hashlib.sha1(key.encode()).hexdigest()[:24].upper())
        self.sections[kind].append((identifier, {"isa": Reference(kind), **fields}))
        return identifier

    def file(self, path, *, build=False):
        relative = path.relative_to(ROOT).as_posix()
        reference = self.add(
            "file:" + relative,
            "PBXFileReference",
            lastKnownFileType=FILE_TYPES.get(path.suffix, "text"),
            path=path.name,
            sourceTree="<group>",
        )
        if build:
            build_file = self.add("build:" + relative, "PBXBuildFile", fileRef=reference)
            if path.suffix == ".swift":
                self.source_builds.append(build_file)
            else:
                self.resource_builds.append(build_file)
        return reference

    def folder(self, path, *, build=False):
        children = []
        for child in sorted(path.iterdir(), key=lambda item: (not item.is_dir(), item.name)):
            if child.name.startswith("."):
                continue
            children.append(
                self.folder(child, build=build)
                if child.is_dir()
                else self.file(child, build=build and child.suffix in {".swift", ".icns"})
            )
        return self.add(
            "group:" + path.relative_to(ROOT).as_posix(),
            "PBXGroup",
            children=children,
            path=path.name,
            sourceTree="<group>",
        )

    def write(self, root):
        lines = [
            "// !$*UTF8*$!",
            "{",
            "\tarchiveVersion = 1;",
            "\tclasses = {};",
            "\tobjectVersion = 56;",
            "\tobjects = {",
        ]
        for kind, objects in sorted(self.sections.items()):
            lines.extend(["", f"/* Begin {kind} section */"])
            for identifier, fields in objects:
                lines.append(f"\t\t{identifier} = {serialize(fields, 2)};")
            lines.append(f"/* End {kind} section */")
        lines.extend(["\t};", f"\trootObject = {root};", "}", ""])
        (PROJECT / "project.pbxproj").write_text("\n".join(lines))


def write_scheme(target):
    scheme = ElementTree.Element("Scheme", LastUpgradeVersion="1600", version="1.3")

    def buildable(parent):
        ElementTree.SubElement(
            parent,
            "BuildableReference",
            BuildableIdentifier="primary",
            BlueprintIdentifier=target,
            BuildableName="Stampede.app",
            BlueprintName="Stampede",
            ReferencedContainer="container:Stampede.xcodeproj",
        )

    action = ElementTree.SubElement(
        scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES"
    )
    entries = ElementTree.SubElement(action, "BuildActionEntries")
    entry = ElementTree.SubElement(
        entries,
        "BuildActionEntry",
        **{f"buildFor{purpose}": "YES" for purpose in (
            "Testing", "Running", "Profiling", "Archiving", "Analyzing"
        )},
    )
    buildable(entry)
    launch = ElementTree.SubElement(
        scheme,
        "LaunchAction",
        buildConfiguration="Debug",
        selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
        selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB",
        launchStyle="0",
        useCustomWorkingDirectory="NO",
        ignoresPersistentStateOnLaunch="NO",
        debugDocumentVersioning="YES",
        allowLocationSimulation="YES",
    )
    buildable(ElementTree.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"))
    profile = ElementTree.SubElement(
        scheme,
        "ProfileAction",
        buildConfiguration="Release",
        shouldUseLaunchSchemeArgsEnv="YES",
        savedToolIdentifier="",
        useCustomWorkingDirectory="NO",
        debugDocumentVersioning="YES",
    )
    buildable(ElementTree.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"))
    ElementTree.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
    ElementTree.SubElement(
        scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES"
    )
    path = PROJECT / "xcshareddata/xcschemes/Stampede.xcscheme"
    path.parent.mkdir(parents=True, exist_ok=True)
    ElementTree.indent(scheme, space="  ")
    path.write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        + ElementTree.tostring(scheme, encoding="unicode")
        + "\n"
    )


def main():
    PROJECT.mkdir(exist_ok=True)
    project = Project()
    children = [
        project.folder(ROOT / "src", build=True),
        project.folder(ROOT / "Tests"),
        project.folder(ROOT / "Resources", build=True),
        project.folder(ROOT / "scripts"),
        project.file(ROOT / "Package.swift"),
        project.file(ROOT / "README.md"),
    ]
    product = project.add(
        "product", "PBXFileReference", explicitFileType="wrapper.application",
        path="Stampede.app", sourceTree="BUILT_PRODUCTS_DIR",
    )
    products = project.add(
        "products", "PBXGroup", children=[product], name="Products", sourceTree="<group>"
    )
    main_group = project.add(
        "main", "PBXGroup", children=children + [products], sourceTree="<group>"
    )
    phases = [
        project.add(
            key, kind, buildActionMask=2147483647, files=files,
            runOnlyForDeploymentPostprocessing=0,
        )
        for key, kind, files in (
            ("sources", "PBXSourcesBuildPhase", project.source_builds),
            ("resources", "PBXResourcesBuildPhase", project.resource_builds),
        )
    ]
    configurations = []
    for configuration in ("Debug", "Release"):
        settings = {
            "ALWAYS_SEARCH_USER_PATHS": "NO",
            "PRODUCT_NAME": "Stampede",
            "PRODUCT_BUNDLE_IDENTIFIER": "com.alanwychen.rotarystamp",
            "SWIFT_VERSION": "6.0",
            "MACOSX_DEPLOYMENT_TARGET": "14.0",
            "SDKROOT": "macosx",
            "INFOPLIST_FILE": "Resources/Info.plist",
            "GENERATE_INFOPLIST_FILE": "NO",
            "CODE_SIGN_STYLE": "Manual",
            "CODE_SIGN_IDENTITY": "-",
            "ENABLE_HARDENED_RUNTIME": "YES",
            "COMBINE_HIDPI_IMAGES": "YES",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if configuration == "Debug" else "-O",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG" if configuration == "Debug" else "",
            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
        }
        if configuration == "Release":
            settings["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"] = "NO"
        configurations.append(project.add(
            configuration, "XCBuildConfiguration", buildSettings=settings, name=configuration
        ))
    configuration_list = project.add(
        "configlist", "XCConfigurationList", buildConfigurations=configurations,
        defaultConfigurationIsVisible=0, defaultConfigurationName="Release",
    )
    target = project.add(
        "target", "PBXNativeTarget", buildConfigurationList=configuration_list,
        buildPhases=phases, buildRules=[], dependencies=[], name="Stampede",
        productName="Stampede", productReference=product,
        productType="com.apple.product-type.application",
    )
    root = project.add(
        "project", "PBXProject", attributes={"LastUpgradeCheck": 1600},
        buildConfigurationList=configuration_list, compatibilityVersion="Xcode 14.0",
        developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "Base"],
        mainGroup=main_group, productRefGroup=products, projectDirPath="", projectRoot="",
        targets=[target],
    )
    project.write(root)
    write_scheme(target)
    print(PROJECT)


if __name__ == "__main__":
    main()
