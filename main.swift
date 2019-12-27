import Foundation
import os

let imageMounts = [
	"VMs": "/Users/Michael/Library/VMware/VMs.sparsebundle"
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

default:
	exit(EX_USAGE)
}
