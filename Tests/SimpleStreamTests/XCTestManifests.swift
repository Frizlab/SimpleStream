#if !canImport(ObjectiveC)
import XCTest

extension SimpleStreamTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__SimpleStreamTests = [
        ("testDataStreamBasicUpToDelimiterRead", testDataStreamBasicUpToDelimiterRead),
        ("testDataStreamReadToEnd", testDataStreamReadToEnd),
        ("testReadBiggerThanBufferData", testReadBiggerThanBufferData),
        ("testReadErrorFromFileHandle", testReadErrorFromFileHandle),
        ("testReadFromSimpleFileHandleStream", testReadFromSimpleFileHandleStream),
        ("testReadSmallerThanBufferData", testReadSmallerThanBufferData),
    ]
}

public func __allTests() -> [XCTestCaseEntry] {
    return [
        testCase(SimpleStreamTests.__allTests__SimpleStreamTests),
    ]
}
#endif