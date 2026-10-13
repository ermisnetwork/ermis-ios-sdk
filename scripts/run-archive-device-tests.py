#!/usr/bin/env python3
"""Host package XCTest on a physical iPhone using an already signed sample app profile.

The temporary host uses the sample's bundle ID and replaces its executable for the
run. The signed sample is reinstalled in finally. Existing app data is retained.
No PIN, real user credential, provisioning contents or private key is printed.
"""
import argparse, plistlib, shutil, subprocess, tempfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--device', required=True)
parser.add_argument('--sample-app', type=Path, required=True)
parser.add_argument('--products', type=Path, required=True)
parser.add_argument('--result', type=Path, required=True)
parser.add_argument('--only-testing', action='append', default=[])
args = parser.parse_args()
selected_tests = [name.removeprefix('ErmisChatTests/') for name in args.only_testing] or ['E2eeArchiveRecoveryTests']
root = Path(tempfile.mkdtemp(prefix='epoch-archive-host-', dir='/private/tmp'))
host = root / 'EpochArchiveHost.app'; host.mkdir()
source = root / 'Host.swift'
source.write_text('''import UIKit
@main final class ArchiveTestHost: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Archive", sessionRole: session.role)
        configuration.delegateClass = ArchiveScene.self
        return configuration
    }
}
final class ArchiveScene: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let view = UIViewController(); view.view.backgroundColor = .systemBackground
        window.rootViewController = view; window.makeKeyAndVisible(); self.window = window
    }
}
''')
info = plistlib.loads((args.sample_app / 'Info.plist').read_bytes())
for key in ['UIMainStoryboardFile','UILaunchStoryboardName','UIApplicationSceneManifest']:
    info.pop(key, None)
info['CFBundleExecutable'] = 'EpochArchiveHost'
info['CFBundleName'] = 'EpochArchiveHost'
info['UILaunchScreen'] = {}
info['UIApplicationSceneManifest'] = {'UIApplicationSupportsMultipleScenes':False, 'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Archive','UISceneDelegateClassName':'EpochArchiveHost.ArchiveScene'}]}}
(host / 'Info.plist').write_bytes(plistlib.dumps(info))
shutil.copy2(args.sample_app / 'embedded.mobileprovision', host / 'embedded.mobileprovision')
sdk = subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'], text=True).strip()
subprocess.run(['xcrun','--sdk','iphoneos','swiftc','-parse-as-library','-module-name','EpochArchiveHost','-target','arm64-apple-ios15.0','-sdk',sdk,str(source),'-Xlinker','-rpath','-Xlinker','@executable_path/Frameworks','-o',str(host/'EpochArchiveHost')],check=True)
entitlements = root / 'entitlements.plist'
with entitlements.open('wb') as stream:
    subprocess.run(['codesign','-d','--entitlements',':-',str(args.sample_app)],stdout=stream,stderr=subprocess.DEVNULL,check=True)
details = subprocess.check_output(['codesign','-dvv',str(args.sample_app)],stderr=subprocess.STDOUT,text=True)
identity = next(line.split('=',1)[1] for line in details.splitlines() if line.startswith('Authority=Apple Development:'))
frameworks = host / 'Frameworks'; frameworks.mkdir()
lottie = args.sample_app / 'Frameworks/Lottie.framework'
if lottie.exists():
    shutil.copytree(lottie, frameworks / 'Lottie.framework')
    subprocess.run(['codesign','--force','--sign',identity,str(frameworks/'Lottie.framework')],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
plugins = host / 'PlugIns'; plugins.mkdir()
bundle = plugins / 'ErmisChatTests.xctest'
shutil.copytree(args.products / 'Debug-iphoneos/ErmisChatTests.xctest', bundle)
subprocess.run(['codesign','--force','--sign',identity,str(bundle)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
subprocess.run(['codesign','--force','--sign',identity,'--entitlements',str(entitlements),str(host)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
original = next(args.products.glob('ErmisChat-Package*.xctestrun'))
run = plistlib.loads(original.read_bytes())
run.pop('CodeCoverageBuildableInfos',None)
target = run['TestConfigurations'][0]['TestTargets'][0]
target.update(TestHostPath=str(host), TestHostBundleIdentifier=info['CFBundleIdentifier'],
    TestBundlePath=str(bundle), IsAppHostedTestBundle=True, IsUITestBundle=False,
    DependentProductPaths=[str(host),str(bundle)], OnlyTestIdentifiers=selected_tests)
target['TestingEnvironmentVariables']['DYLD_INSERT_LIBRARIES'] = '__PLATFORMS__/iPhoneOS.platform/Developer/usr/lib/libXCTestBundleInject.dylib'
run_file = root / 'ArchiveDevice.xctestrun'; run_file.write_bytes(plistlib.dumps(run))
command = ['xcodebuild','test-without-building','-xctestrun',str(run_file),'-destination','id='+args.device,
    '-parallel-testing-enabled','NO','-collect-test-diagnostics','never','-resultBundlePath',str(args.result)]
print('archive_device_test stage=host_prepared',flush=True)
try:
    result = subprocess.run(command).returncode
finally:
    restore = subprocess.run(['xcrun','devicectl','device','install','app','--device',args.device,str(args.sample_app)], stdout=subprocess.DEVNULL)
    print('archive_device_test stage=sample_restored' if restore.returncode == 0 else 'archive_device_test stage=sample_restore_failed',flush=True)
raise SystemExit(result if result != 0 else restore.returncode)
