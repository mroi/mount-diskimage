import Foundation
import os

let imageMounts = [
	"Virtual Machines": "/Users/Michael/Library/VM/VM.sparsebundle"
].filter {
	// only include existing images
	FileManager.default.fileExists(atPath: $0.value)
}

switch CommandLine.argc {
case 1:
	print(imageMounts.keys.joined(separator: "\n"))

case 2:
	guard let image = imageMounts[CommandLine.arguments[1]] else {
		exit(EX_USAGE)
	}

	// drop privileges to the owner of the disk image
	let attributes = try? FileManager.default.attributesOfItem(atPath: image)
	if let group = (attributes?[.groupOwnerAccountID] as? NSNumber)?.uint32Value {
		setgid(group)
	}
	if let user = (attributes?[.ownerAccountID] as? NSNumber)?.uint32Value {
		setuid(user)
	}

	// compact the disk image for about 10% of mount attempts
	let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
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
	let result: AttachInfo
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
			os_log("attaching the disk image ‘%{public}s’ failed with error code %d", image, status)
			exit(EX_UNAVAILABLE)
		}

		result = try AttachInfo(from: data)
	}
	catch {
		exit(EX_OSERR)
	}

	// run filesystem check on the attached image
	do {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/sbin/fsck_\(result.type)")
		process.arguments = ["-q", result.device]
		process.standardOutput = FileHandle.nullDevice
		try process.run()
		process.waitUntilExit()

		let status = process.terminationStatus
		if status != EX_OK {
			os_log("the file system in disk image ‘%{public}s’ needs repair, error code: %d", image, status)

			let process = Process()
			process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
			process.arguments = ["repairDisk", result.device]
			process.standardOutput = FileHandle.nullDevice
			try process.run()
			process.waitUntilExit()

			let status = process.terminationStatus
			if status != EX_OK {
				os_log("the file system could not be repaired, error code: %d", status)
			}
		}
	}
	catch {
		exit(EX_OSERR)
	}

	print("-fstype=\(result.type),nobrowse,nodev,nosuid :\(result.device)")

default:
	exit(EX_USAGE)
}
