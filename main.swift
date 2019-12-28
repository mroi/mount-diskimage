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
	guard let image = imageMounts[CommandLine.arguments[1]] else {
		exit(EX_USAGE)
	}
	os_log("asked to mount %{public}s", image)
default:
	exit(EX_USAGE)
}
