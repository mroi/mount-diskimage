import Foundation

/**
Decode the property list resulting from `hdiutil attach` and extract the primary mountable volume.
*/
struct AttachInfo: Decodable {
	let device: String
	let type: String

	private enum AttachKeys: String, CodingKey {
		case systemEntities = "system-entities"
	}
	private enum EntityKeys: String, CodingKey {
		case device = "dev-entry"
		case mountable = "potentially-mountable"
		case volumeType = "volume-kind"
	}

	init(from decoder: Decoder) throws {
		let allowedVolumeTypes = ["apfs", "hfs"]
		var entities = try decoder
			.container(keyedBy: AttachKeys.self)
			.nestedUnkeyedContainer(forKey: .systemEntities)
		while !entities.isAtEnd {
			let entity = try entities.nestedContainer(keyedBy: EntityKeys.self)
			let mountable = try entity.decodeIfPresent(Bool.self, forKey: .mountable) ?? false
			let volumeType = try entity.decodeIfPresent(String.self, forKey: .volumeType) ?? ""
			if mountable && allowedVolumeTypes.contains(volumeType) {
				device = try entity.decode(String.self, forKey: .device)
				type = volumeType
				return
			}
		}
		let context = DecodingError.Context(codingPath: [AttachKeys.systemEntities], debugDescription: "no matching mountable volume found")
		throw DecodingError.keyNotFound(EntityKeys.device, context)
	}

	init(from data: Data) throws {
		let decoder = PropertyListDecoder()
		self = try decoder.decode(AttachResult.self, from: data)
	}
}
