#!/usr/bin/env python3
"""Generate the dependency-free native app project from checked-in Swift sources."""
import hashlib
from pathlib import Path

root = Path(__file__).resolve().parent.parent
project = root / 'Stampede.xcodeproj'
project.mkdir(exist_ok=True)
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def quote(value): return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'
objects = []
def obj(name, content): objects.append(f'{uid(name)} = {{ {content} }};'); return uid(name)
sources = sorted((root / 'Sources').rglob('*.swift'))
files, builds = [], []
for source in sources:
    path = source.relative_to(root).as_posix()
    files.append(obj('file:' + path, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(path)}; sourceTree = SOURCE_ROOT;'))
    builds.append(obj('build:' + path, f'isa = PBXBuildFile; fileRef = {files[-1]};'))
icon = obj('icon', 'isa = PBXFileReference; lastKnownFileType = image.icns; path = Resources/Stampede.icns; sourceTree = SOURCE_ROOT;')
iconbuild = obj('iconbuild', f'isa = PBXBuildFile; fileRef = {icon};')
resources = obj('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({iconbuild}); runOnlyForDeploymentPostprocessing = 0;')
files.append(icon)
product = obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = Stampede.app; sourceTree = BUILT_PRODUCTS_DIR;')
products = obj('products', f'isa = PBXGroup; children = ({product}); name = Products; sourceTree = "<group>";')
main = obj('main', f'isa = PBXGroup; children = ({", ".join(files + [products])}); sourceTree = "<group>";')
phase = obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(builds)}); runOnlyForDeploymentPostprocessing = 0;')
configs = []
for config in ('Debug', 'Release'):
    settings = {
        'ALWAYS_SEARCH_USER_PATHS': 'NO', 'PRODUCT_NAME': 'Stampede', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.alanwychen.rotarystamp',
        'SWIFT_VERSION': '6.0', 'MACOSX_DEPLOYMENT_TARGET': '14.0', 'SDKROOT': 'macosx',
        'INFOPLIST_FILE': 'Resources/Info.plist', 'GENERATE_INFOPLIST_FILE': 'NO',
        'CODE_SIGN_STYLE': 'Manual', 'CODE_SIGN_IDENTITY': '-', 'COMBINE_HIDPI_IMAGES': 'YES',
        'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if config == 'Debug' else '-O',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG' if config == 'Debug' else '',
        'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/../Frameworks'
    }
    body = ' '.join(f'{key} = {quote(value)};' for key, value in settings.items())
    configs.append(obj(config, f'isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {config};'))
configlist = obj('configlist', f'isa = XCConfigurationList; buildConfigurations = ({", ".join(configs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target = obj('target', f'isa = PBXNativeTarget; buildConfigurationList = {configlist}; buildPhases = ({phase}, {resources}); buildRules = (); dependencies = (); name = Stampede; productName = Stampede; productReference = {product}; productType = "com.apple.product-type.application";')
proj = obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {configlist}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {main}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target});')
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {proj}; }}\n')
scheme = project / 'xcshareddata/xcschemes/Stampede.xcscheme'
scheme.parent.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Stampede.app" BlueprintName="Stampede" ReferencedContainer="container:Stampede.xcodeproj"/>'
scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(project)
