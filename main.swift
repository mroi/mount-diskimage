import Foundation
import os

let imageMounts = [
	"Michael-VM": "/Users/Michael/Library/VM/VM.sparsebundle"
].filter {
	// only include existing images
	FileManager.default.fileExists(atPath: $0.value)
}

switch CommandLine.argc {
case 1:
	print(imageMounts.keys.joined(separator: "\n"))

case 2:
	let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
	guard let image = imageMounts[CommandLine.arguments[1]] else {
		exit(EX_USAGE)
	}

	// compact the disk image for about 10% of mount attempts
	if Float.random(in: 0...1) < 0.1 {
		guard let process = try? Process.run(hdiutil, arguments: ["compact", image]) else {
			exit(EX_OSERR)
		}
		process.waitUntilExit()
		if process.terminationStatus != EX_OK {
			os_log("compaction failed for disk image ‘%{public}s’", image)
		} else {
			os_log("compacted disk image ‘%{public}s’", image)
		}
	}

	// attach the image without mounting it
	let result: AttachResult
	do {
		let process = Process()
		let pipe = Pipe()
		process.executableURL = hdiutil
		process.arguments = ["attach", image, "-plist", "-nomount", "-noverify", "-noautofsck"]
		process.standardOutput = pipe
		try process.run()
		process.waitUntilExit()

		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		let status = process.terminationStatus
		if !(data.count > 0 && status == EX_OK) {
			os_log("attaching the disk image ‘%{public}s’ failed with error code %{errno}d", image, status)
			exit(EX_UNAVAILABLE)
		}

		result = try AttachResult(from: data)
	}
	catch {
		exit(EX_OSERR)
	}

	print("-fstype=\(result.type),nobrowse,nodev,nosuid :\(result.device)")

default:
	exit(EX_USAGE)
}
