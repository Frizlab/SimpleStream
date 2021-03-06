/*
 * SimpleGenericReadStream.swift
 * SimpleStream
 *
 * Created by François Lamboley on 20/08/2017.
 */

import Foundation



public protocol GenericReadStream {
	
	/**
	Read at most maxLength bytes from the stream and put it at the given memory
	location. (Indeed the given buffer must be at minimum of size `len`.)
	
	- Important: The method might rebind the memory from the pointer.
	- Parameters:
	  - buffer: The memory location in which to read the data.
	  - len: The maximum number of bytes to read.
	- Returns: The number of bytes acutally read.
	- Throws: In case of an error reading the stream, throws an error. */
	func read(_ buffer: UnsafeMutableRawPointer, maxLength len: Int) throws -> Int
	
}


public final class SimpleGenericReadStream : SimpleReadStream {
	
	public let sourceStream: GenericReadStream
	
	/** The buffer size the client wants. Sometimes we have to allocated a bigger
	buffer though because the requested data would not fit in this size. */
	public let defaultBufferSize: Int
	/** The number of bytes by which to increment the current buffer size when
	reading up to given delimiters and there is no space left in the buffer. */
	public let bufferSizeIncrement: Int
	
	public var currentReadPosition = 0
	
	public var readSizeLimit: Int?
	@available(*, deprecated, message: "Use readSizeLimit")
	public var streamReadSizeLimit: Int? {
		get {return readSizeLimit}
		set {readSizeLimit = newValue}
	}
	
	/** Initializes a SimpleInputStream.
	
	- Parameter stream: The stream to read data from. Must be opened.
	- Parameter bufferSize: The size of the buffer to use to read from the
	stream. Sometimes, more memory might be allocated if needed for some reads.
	- Parameter streamReadSizeLimit: The maximum number of bytes allowed to be
	read from the stream.
	*/
	public init(stream: GenericReadStream, bufferSize size: Int, bufferSizeIncrement sizeIncrement: Int, streamReadSizeLimit streamLimit: Int?) {
		assert(size > 0)
		
		sourceStream = stream
		
		defaultBufferSize = size
		bufferSizeIncrement = sizeIncrement
		
		buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<UInt8>.alignment)
		bufferSize = size
		bufferStartPos = 0
		bufferValidLength = 0
		
		totalReadBytesCount = 0
		readSizeLimit = streamLimit
	}
	
	deinit {
		buffer.deallocate()
	}
	
	public func readData<T>(size: Int, _ handler: (UnsafeRawBufferPointer) throws -> T) throws -> T {
		let ret = try readDataNoCurrentPosIncrement(size: size)
		currentReadPosition += size
		assert(ret.count == size)
		return try handler(ret)
	}
	
	public func readData<T>(upTo delimiters: [Data], matchingMode: DelimiterMatchingMode, includeDelimiter: Bool, _ handler: (UnsafeRawBufferPointer, Data) throws -> T) throws -> T {
		let (minDelimiterLength, maxDelimiterLength) = delimiters.reduce((delimiters.first?.count ?? 0, 0), { (min($0.0, $1.count), max($0.1, $1.count)) })
		
		var unmatchedDelimiters = Array(delimiters.enumerated())
		var matchedDatas = [Match]()
		
		var searchOffset = 0
		repeat {
			assert(bufferValidLength - searchOffset >= 0)
			var bufferStart = buffer + bufferStartPos
			let bufferSearchData = UnsafeRawBufferPointer(start: bufferStart + searchOffset, count: bufferValidLength - searchOffset)
			if let match = matchDelimiters(inData: bufferSearchData, usingMatchingMode: matchingMode, includeDelimiter: includeDelimiter, minDelimiterLength: minDelimiterLength, withUnmatchedDelimiters: &unmatchedDelimiters, matchedDatas: &matchedDatas) {
				let returnedLength = searchOffset + match.length
				bufferStartPos += returnedLength
				bufferValidLength -= returnedLength
				currentReadPosition += returnedLength
				return try handler(UnsafeRawBufferPointer(start: bufferStart, count: returnedLength), delimiters[match.delimiterIdx])
			}
			
			/* No confirmed match. We have to continue reading the data! */
			searchOffset = max(0, bufferValidLength - maxDelimiterLength + 1)
			
			if bufferStartPos + bufferValidLength >= bufferSize {
				/* The buffer is not big enough to hold new data... Let's move the
				 * data to the beginning of the buffer or create a new buffer. */
				if bufferStartPos > 0 {
					/* We can move the data to the beginning of the buffer. */
					assert(bufferStart != buffer)
					buffer.copyMemory(from: bufferStart, byteCount: bufferValidLength)
					bufferStart = buffer
					bufferStartPos = 0
				} else {
					/* The buffer is not big enough anymore. We need to create a new,
					 * bigger one. */
					assert(bufferStartPos == 0)
					
					let oldBuffer = buffer
					
					bufferSize += bufferSizeIncrement
					buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: MemoryLayout<UInt8>.alignment)
					buffer.copyMemory(from: bufferStart, byteCount: bufferValidLength)
					bufferStart = buffer
					
					oldBuffer.deallocate()
				}
			}
			
			/* Let's read from the stream now! */
			let sizeToRead: Int
			let unmaxedSizeToRead = bufferSize - (bufferStartPos + bufferValidLength) /* The remaining space in the buffer */
			if let maxTotalReadBytesCount = readSizeLimit {sizeToRead = min(unmaxedSizeToRead, max(0, maxTotalReadBytesCount - totalReadBytesCount) /* Number of bytes remaining allowed to be read */)}
			else                                          {sizeToRead =     unmaxedSizeToRead}
			
			assert(sizeToRead >= 0)
			if sizeToRead == 0 {/* End of the (allowed) data */break}
			let sizeRead = try sourceStream.read(bufferStart + bufferValidLength, maxLength: sizeToRead)
			guard sizeRead > 0 else {/* End of the data */break}
			bufferValidLength += sizeRead
			totalReadBytesCount += sizeRead
			assert(readSizeLimit == nil || totalReadBytesCount <= readSizeLimit!)
		} while true
		
		if let match = findBestMatch(fromMatchedDatas: matchedDatas, usingMatchingMode: matchingMode) {
			bufferStartPos += match.length
			bufferValidLength -= match.length
			currentReadPosition += match.length
			return try handler(UnsafeRawBufferPointer(start: buffer + bufferStartPos, count: match.length), delimiters[match.delimiterIdx])
		}
		
		if delimiters.count > 0 {throw SimpleStreamError.delimitersNotFound}
		else {
			/* We return the whole data. */
			let returnedLength = bufferValidLength
			let bufferStart = buffer + bufferStartPos
			
			currentReadPosition += bufferValidLength
			bufferStartPos += bufferValidLength
			bufferValidLength = 0
			
			return try handler(UnsafeRawBufferPointer(start: bufferStart, count: returnedLength), Data())
		}
	}
	
	/* ***************
	   MARK: - Private
	   *************** */
	
	/* Note: We choose not to use UnsafeMutableRawBufferPointer as we’ll do many
	 *       pointer arithmetic, it wouldn’t be very practical. */
	
	/** The current buffer in use. Its size should be `defaultBufferSize` most of
	the time. */
	private var buffer: UnsafeMutableRawPointer
	private var bufferSize: Int
	private var bufferStartPos: Int
	private var bufferValidLength: Int
	
	/** The total number of bytes read from the source stream. */
	private var totalReadBytesCount = 0
	
	private func readDataNoCurrentPosIncrement(size: Int) throws -> UnsafeRawBufferPointer {
		let bufferStart = buffer + bufferStartPos
		
		switch size {
		case let s where s <= bufferSize - bufferStartPos:
			/* The buffer is big enough to hold the size we want to read, from
			 * buffer start pos. */
			return try readDataAssumingBufferIsBigEnough(dataSize: size, allowReadingMore: true)
			
		case let s where s <= defaultBufferSize:
			/* The default sized buffer is enough to hold the size we want to read.
			 * Let's copy the current buffer to the beginning of the default sized
			 * buffer! And get rid of the old (bigger) buffer if needed. */
			if bufferSize != defaultBufferSize {
				assert(bufferSize > defaultBufferSize)
				
				let oldBuffer = buffer
				buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: MemoryLayout<UInt8>.alignment)
				buffer.copyMemory(from: bufferStart, byteCount: bufferValidLength)
				bufferSize = defaultBufferSize
				oldBuffer.deallocate()
			} else {
				buffer.copyMemory(from: bufferStart, byteCount: bufferValidLength)
			}
			bufferStartPos = 0
			return try readDataAssumingBufferIsBigEnough(dataSize: size, allowReadingMore: true)
			
		case let s where s <= bufferSize:
			/* The current buffer total size is enough to hold the size we want to
			 * read. However, we must relocate data in the buffer so the buffer
			 * start position is 0. */
			buffer.copyMemory(from: bufferStart, byteCount: bufferValidLength)
			bufferStartPos = 0
			return try readDataAssumingBufferIsBigEnough(dataSize: size, allowReadingMore: true)
			
		default:
			/* The buffer is not big enough to hold the data we want to read. We
			 * must create a new buffer. */
//			print("Got too small buffer of size \(bufferSize) to read size \(size) from buffer. Retrying with a bigger buffer.")
			let oldBuffer = buffer
			buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<UInt8>.alignment)
			buffer.copyMemory(from: bufferStart, byteCount: bufferValidLength)
			bufferSize = size
			bufferStartPos = 0
			oldBuffer.deallocate()
			
			return try readDataAssumingBufferIsBigEnough(dataSize: size, allowReadingMore: false /* Not actually needed as the buffer size is exactly of the required size… */)
		}
	}
	
	/** Reads and return the asked size from buffer and completes with the stream
	if needed. Uses the buffer to read the first bytes and store the bytes read
	from the stream if applicable. The buffer must be big enough to contain the
	asked size **from `bufferStartPos`**.
	
	- Parameter dataSize: The size of the data to return.
	- Parameter allowReadingMore: If `true`, this method may read more data than
	what is actually needed from the stream.
	- Throws: `SimpleStreamError` in case of error.
	- Returns: The read data from the buffer or the stream if necessary.
	*/
	private func readDataAssumingBufferIsBigEnough(dataSize size: Int, allowReadingMore: Bool) throws -> UnsafeRawBufferPointer {
		assert(bufferSize - bufferStartPos >= size)
		
		let bufferStart = buffer + bufferStartPos
		if bufferValidLength < size {
			/* We must read from the stream. */
			if let maxTotalReadBytesCount = readSizeLimit, maxTotalReadBytesCount < totalReadBytesCount || size - bufferValidLength /* To read from stream */ > maxTotalReadBytesCount - totalReadBytesCount /* Remaining allowed bytes to be read */ {
				/* We have to read more bytes from the stream than allowed. We bail. */
				throw SimpleStreamError.streamReadSizeLimitReached
			}
			
			repeat {
				let sizeToRead: Int
				if !allowReadingMore {sizeToRead = size - bufferValidLength /* Checked to fit in the remaining bytes allowed to be read in "if" before this loop */}
				else {
					let unmaxedSizeToRead = bufferSize - (bufferStartPos + bufferValidLength) /* The remaining space in the buffer */
					if let maxTotalReadBytesCount = readSizeLimit {sizeToRead = min(unmaxedSizeToRead, maxTotalReadBytesCount - totalReadBytesCount /* Number of bytes remaining allowed to be read */)}
					else                                          {sizeToRead =     unmaxedSizeToRead}
				}
				assert(sizeToRead > 0)
				let sizeRead = try sourceStream.read(bufferStart + bufferValidLength, maxLength: sizeToRead)
				guard sizeRead > 0 else {throw SimpleStreamError.noMoreData}
				bufferValidLength += sizeRead
				totalReadBytesCount += sizeRead
				assert(readSizeLimit == nil || totalReadBytesCount <= readSizeLimit!)
			} while bufferValidLength < size /* Reading until we have enough data in the buffer. */
		}
		
		bufferValidLength -= size
		bufferStartPos += size
		return UnsafeRawBufferPointer(start: bufferStart, count: size)
	}
	
}
