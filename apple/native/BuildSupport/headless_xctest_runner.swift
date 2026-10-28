// Component tests only: no scene activation, UI automation or physical-display claim.
import XCTest
import UIKit
import Darwin
guard let expectedHome=ProcessInfo.processInfo.environment["VETA_HEADLESS_HOME"], NSHomeDirectory()==expectedHome else {print("ISOLATED_HOME_FAIL \(NSHomeDirectory())");exit(5)}
print("HEADLESS_HOME \(NSHomeDirectory())")
print("HEADLESS_PID \(getpid())");fflush(stdout)
let base=Bundle.main.bundleURL
print("HEADLESS_BUNDLE \(base.path)")
guard let library=dlopen(base.appendingPathComponent("Frameworks/libVetaJITLabHeadless.dylib").path,RTLD_NOW|RTLD_GLOBAL) else {print("LOAD_APP_FAIL \(String(cString:dlerror()))");exit(2)}
let tests=Bundle(url:base.appendingPathComponent("PlugIns/"+CommandLine.arguments[1]+".xctest"))!
do {try tests.loadAndReturnError()} catch {print("LOAD_TESTS_FAIL \(error)");exit(3)}
let suite=XCTestSuite(name:"VETA headless component tests")
let methods=(ProcessInfo.processInfo.environment["VETA_HEADLESS_METHODS"] ?? "").split(separator:"\n").map(String.init)
var selected=Set<String>()
for name in CommandLine.arguments.dropFirst(2) {
    guard let testClass=NSClassFromString(name) as? XCTestCase.Type else {print("CLASS_FAIL \(name)");exit(4)}
    let candidates=XCTestSuite(forTestCaseClass:testClass)
    if methods.isEmpty {suite.addTest(candidates)}
    else {for test in candidates.tests {for method in methods where test.name.hasSuffix(" "+method+"]") {suite.addTest(test);selected.insert(method);print("HEADLESS_SELECTED \(test.name)")}}}
}
guard methods.isEmpty || selected==Set(methods) else {print("METHOD_NOT_FOUND");exit(6)}
suite.run()
let run=suite.testRun!
print("HEADLESS_XCTEST executed=\(run.executionCount) failures=\(run.totalFailureCount) skipped=\(run.skipCount)")
exit(run.totalFailureCount==0 && run.executionCount>run.skipCount ? 0:1)
