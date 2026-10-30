"""Generate a dependency-free Xcode project. Run again after adding Swift sources."""
from pathlib import Path
import hashlib
import plistlib

root = Path(__file__).resolve().parent
objects = {}
def uid(value): return hashlib.sha1(value.encode()).hexdigest()[:24].upper()
def obj(key, value):
    objects[uid(key)] = value
    return uid(key)
def quote(value): return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'
def render(value):
    if isinstance(value, dict): return '{ ' + ' '.join(f'{quote(k)} = {render(v)};' for k, v in value.items()) + ' }'
    if isinstance(value, list): return '(' + ', '.join(render(x) for x in value) + ')'
    return quote(str(value))
def configs(key, settings):
    ids = []
    for config in ['Debug', 'Release']:
        opts = dict(settings)
        opts['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone' if config == 'Debug' else '-O'
        if config == 'Debug': opts['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
        ids.append(obj(key + config, dict(isa='XCBuildConfiguration', name=config, buildSettings=opts)))
    return obj(key + 'configs', dict(isa='XCConfigurationList', buildConfigurations=ids, defaultConfigurationIsVisible=0, defaultConfigurationName='Release'))
products = []
groups = []
targets = []
for name, test in [('Lifeblood', False), ('LifebloodTests', True)]:
    files = []
    builds = []
    for file in sorted((root / name).glob('*.swift')):
        ref = obj(str(file.relative_to(root)), dict(isa='PBXFileReference', lastKnownFileType='sourcecode.swift', path=file.name, sourceTree='<group>'))
        files.append(ref)
        builds.append(obj('build:' + file.name, dict(isa='PBXBuildFile', fileRef=ref)))
    groups.append(obj(name + 'group', dict(isa='PBXGroup', path=name, sourceTree='<group>', children=files)))
    product = obj(name + 'product', dict(isa='PBXFileReference', explicitFileType='wrapper.cfbundle' if test else 'wrapper.application', path=name + ('.xctest' if test else '.app'), sourceTree='BUILT_PRODUCTS_DIR'))
    products.append(product)
    phases = [obj(name + 'sources', dict(isa='PBXSourcesBuildPhase', buildActionMask=2147483647, files=builds, runOnlyForDeploymentPostprocessing=0)), obj(name + 'frameworks', dict(isa='PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)), obj(name + 'resources', dict(isa='PBXResourcesBuildPhase', buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0))]
    settings = dict(PRODUCT_NAME='$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER='au.lifeblood.' + ('tests' if test else 'tracker'), SWIFT_VERSION='5.0', IPHONEOS_DEPLOYMENT_TARGET='17.0', TARGETED_DEVICE_FAMILY='1', SDKROOT='iphoneos', CODE_SIGN_STYLE='Automatic', GENERATE_INFOPLIST_FILE='YES', ENABLE_TESTABILITY='YES')
    deps = []
    if test:
        settings.update(TEST_HOST='$(BUILT_PRODUCTS_DIR)/Lifeblood.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Lifeblood', BUNDLE_LOADER='$(TEST_HOST)')
        proxy = obj('proxy', dict(isa='PBXContainerItemProxy', containerPortal=uid('project'), proxyType=1, remoteGlobalIDString=uid('Lifebloodtarget'), remoteInfo='Lifeblood'))
        deps = [obj('testdep', dict(isa='PBXTargetDependency', target=uid('Lifebloodtarget'), targetProxy=proxy))]
    else:
        settings.update(INFOPLIST_FILE='Info.plist', GENERATE_INFOPLIST_FILE='NO')
    targets.append(obj(name + 'target', dict(isa='PBXNativeTarget', name=name, productName=name, productReference=product, productType='com.apple.product-type.bundle.unit-test' if test else 'com.apple.product-type.application', buildConfigurationList=configs(name, settings), buildPhases=phases, buildRules=[], dependencies=deps)))
prodgroup = obj('products', dict(isa='PBXGroup', name='Products', sourceTree='<group>', children=products))
main = obj('main', dict(isa='PBXGroup', sourceTree='<group>', children=groups + [prodgroup]))
project = obj('project', dict(isa='PBXProject', attributes=dict(LastUpgradeCheck='1600'), buildConfigurationList=configs('project', dict(CLANG_ENABLE_MODULES='YES', IPHONEOS_DEPLOYMENT_TARGET='17.0')), compatibilityVersion='Xcode 14.0', developmentRegion='en', knownRegions=['en', 'Base'], mainGroup=main, productRefGroup=prodgroup, projectDirPath='', projectRoot='', targets=targets))
folder = root / 'Lifeblood.xcodeproj'
folder.mkdir(exist_ok=True)
(folder / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + render(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=project)) + '\n')
info = dict(CFBundleDevelopmentRegion='$(DEVELOPMENT_LANGUAGE)', CFBundleExecutable='$(EXECUTABLE_NAME)', CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)', CFBundleInfoDictionaryVersion='6.0', CFBundleName='$(PRODUCT_NAME)', CFBundlePackageType='APPL', CFBundleShortVersionString='1.0', CFBundleVersion='1', CFBundleDisplayName='LIFEBLOOD', UILaunchScreen={}, UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes': False}, NSCalendarsFullAccessUsageDescription='Export reminders you choose to your calendar.', NSCameraUsageDescription='Photograph your prescription to recognise its text on this iPhone. Review all details before saving.', UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait'])
(root / 'Info.plist').write_bytes(plistlib.dumps(info))
schemes = folder / 'xcshareddata' / 'xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
def reference(name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(name + "target")}" BuildableName="{name}{".xctest" if name.endswith("Tests") else ".app"}" BlueprintName="{name}" ReferencedContainer="container:Lifeblood.xcodeproj"/>'
(schemes / 'Lifeblood.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference('Lifeblood')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{reference('LifebloodTests')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference('Lifeblood')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference('Lifeblood')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Generated ios/Lifeblood.xcodeproj')
