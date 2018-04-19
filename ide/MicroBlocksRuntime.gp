// SmallCompiler.gp - A blocks compiler for SmallVM
// John Maloney, April, 2017

to smallRuntime aScripter {
	if (isNil (global 'smallRuntime')) {
		setGlobal 'smallRuntime' (new 'SmallRuntime' aScripter)
	}
	return (global 'smallRuntime')
}

defineClass SmallRuntime scripter chunkIDs chunkRunning msgDict portName port pingSentMSecs lastPingRecvMSecs recvBuf

method scripter SmallRuntime { return scripter }
method setScripter SmallRuntime aScripter { scripter = aScripter }

method evalOnBoard SmallRuntime aBlock showBytes {
	if (isNil showBytes) { showBytes = false }
	if showBytes {
		bytes = (chunkBytesForBlock this aBlock)
		print (join 'Bytes for chunk ' id ':') bytes
		print '----------'
		return
	}

	// save all chunks, including functions and broadcast receivers
	// (it would be more efficient to save only chunks that have changed)
	saveAllChunks this
	if (isNil (ownerThatIsA (morph aBlock) 'ScriptEditor')) {
		// running a block from the palette, not included in saveAllChunks
		saveChunk this aBlock
	}
	runChunk this (chunkIdFor this aBlock)
}

method chunkTypeForBlock SmallRuntime aBlock {
	expr = (expression aBlock)
	op = (primName expr)
	if ('whenStarted' == op) { chunkType = 4
	} ('whenCondition' == op) { chunkType = 5
	} ('whenBroadcastReceived' == op) { chunkType = 6
	} (isClass expr 'Command') { chunkType = 1
	} (isClass expr 'Reporter') { chunkType = 2
	} ('nop' == op) { chunkType = 3 // xxx need a better test for function def hats
	}
	return chunkType
}

method chunkBytesForBlock SmallRuntime aBlock {
	compiler = (initialize (new 'SmallCompiler'))
	code = (instructionsFor compiler aBlock)
	bytes = (list)
	for item code {
		if (isClass item 'Array') {
			addBytesForInstructionTo compiler item bytes
		} (isClass item 'Integer') {
			addBytesForIntegerLiteralTo compiler item bytes
		} (isClass item 'String') {
			addBytesForStringLiteral compiler item bytes
		} else {
			error 'Instruction must be an Array or String:' item
		}
	}
	return bytes
}

method showInstructions SmallRuntime aBlock {
	// Print the instructions for the given stack.

	compiler = (initialize (new 'SmallCompiler'))
	code = (instructionsFor compiler (topBlock aBlock))
	for item code {
		if (not (isClass item 'Array')) {
			print item
		} ('pushImmediate' == (first item)) {
			arg = (at item 2)
			if (1 == (arg & 1)) {
				arg = (arg >> 1) // decode integer
			} (0 == arg) {
				arg = false
			} (4 == arg) {
				arg = true
			}
			print 'pushImmediate' arg
		} ('pushBigImmediate' == (first item)) {
			print 'pushBigImmediate' // don't show arg count; could be confusing
		} ('callFunction' == (first item)) {
			arg = (at item 2)
			calledChunkID = ((arg >> 8) & 255)
			argCount = (arg & 255)
			print 'callFunction' calledChunkID argCount
		} else {
			callWith 'print' item // print the array elements
		}
	}
	print '----------'
}

method chunkIdFor SmallRuntime aBlock {
	if (isNil chunkIDs) { chunkIDs = (dictionary) }
	entry = (at chunkIDs aBlock nil)
	if (isNil entry) {
		id = (count chunkIDs)
		entry = (array id aBlock) // block -> <id> <last expression>
		atPut chunkIDs aBlock entry
	}
	return (first entry)
}

method lookupChunkID SmallRuntime aBlock {
	// If the block has been assigned a chunkID, return it. Otherwise, return nil.

	if (isNil chunkIDs) { return nil }
	entry = (at chunkIDs aBlock nil)
	if (isNil entry) { return nil }
	return (first entry)
}

method deleteChunkForBlock SmallRuntime aBlock {
	if (isNil chunkIDs) { chunkIDs = (dictionary) }
	entry = (at chunkIDs aBlock nil)
	if (notNil entry) {
		remove chunkIDs aBlock
		chunkID = (first entry)
		sendMsg this 'deleteChunkMsg' chunkID
	}
}

method resetBoard SmallRuntime {
	// Stop everyting, clear all code, and reset the board.

	sendStopAll this
	sendMsg this 'deleteAllCodeMsg' // delete all code from board
	waitMSecs 50 // leave time to write to flash or next message will be missed
	sendMsg this 'systemResetMsg' // send the reset message
	chunkIDs = (dictionary) // start over
return

	// The following reset code is not currently used
	// First try closing the serial port, opening it at 1200 baud,
	// then closing and reopening the port at the normal speed.
	// This works only for certain models of the Arduino. It does not work for non-Arduinos.
	closeSerialPort port
	port = (openSerialPort portName 1200)
	closeSerialPort port
	port = nil
	ensurePortOpen this // reopen the port
	recvBuf = nil
}

method selectPort SmallRuntime {
	portList = (list)
	if ('Win' == (platform)) {
		portList = (listSerialPorts)
		if (isEmpty portList) {
			portList = (list)
			for n 32 { add portList (join 'COM' n) }
		}
	} else {
		for fn (listFiles '/dev') {
			if (or (notNil (nextMatchIn 'usb' (toLowerCase fn) )) // MacOS
				   (notNil (nextMatchIn 'acm' (toLowerCase fn) ))) { // Linux
				add portList fn
			}
		}
		// Mac OS (and perhaps Linuxes) list a port as both cu.<name> and tty.<name>
		for s (copy portList) {
			if (beginsWith s 'tty.') {
				if (contains portList (join 'cu.' (substring s 5))) {
					remove portList s
				}
			}
		}
		names = (dictionary)
		addAll names portList

	}
	menu = (menu 'Serial port:' (action 'setPort' this) true)
	for s portList { addItem menu s }
	addLine menu
	addItem menu 'other'
	popUpAtHand menu (global 'page')
}

method setPort SmallRuntime newPortName {
	if ('other' == newPortName) {
		newPortName = (prompt (global 'page') 'Port name?' 'none')
		if ('' == newPortName) { return }
	}
	if (notNil port) {
		closeSerialPort port
		port = nil
	}
	if (or (isNil newPortName) ('none' == newPortName)) { // just close port
		portName = nil
	} else {
		portName = (join '/dev/' newPortName)
		if ('Win' == (platform)) { portName = newPortName }
		ensurePortOpen this
	}
	// update the connection indicator more quickly than it would otherwise
	lastPingRecvMSecs = 0 // force ping timeout
	updateIndicator (findMicroBlocksEditor)
	waitMSecs 20
	processMessages this
	updateIndicator (findMicroBlocksEditor)
}

method connectionStatus SmallRuntime {
	pingSendInterval = 2000 // msecs between pings
	if (isNil pingSentMSecs) { pingSentMSecs = 0 }
	if (isNil lastPingRecvMSecs) { lastPingRecvMSecs = 0 }

	if (or (isNil port) (not (isOpenSerialPort port))) {
		port = nil
		return 'not connected'
	}
	if (((msecsSinceStart) - pingSentMSecs) > pingSendInterval) {
		sendMsg this 'pingMsg'
		pingSentMSecs = (msecsSinceStart)
	}
	msecsSinceLastPing = ((msecsSinceStart) - lastPingRecvMSecs)
	if (msecsSinceLastPing < (pingSendInterval + 200)) {
		return 'connected'
	}
	return 'board not responding'
}

method getVersion SmallRuntime {
	sendMsg this 'getVersionMsg'
}

method showVersion SmallRuntime versionString {
	inform (global 'page') (join 'MicroBlocks Virtual Machine' (newline) versionString)
}

method clearBoardIfConnected SmallRuntime {
	if (notNil port) { resetBoard this }
}

method sendDeleteAll SmallRuntime { sendMsg this 'deleteAllCodeMsg' }

method sendStopAll SmallRuntime {
	sendMsg this 'stopAllMsg'
	allStopped this
}

method sendStartAll SmallRuntime {
	saveAllChunks this
	sendMsg this 'startAllMsg'
}

method saveAllChunks SmallRuntime {
	for aBlock (sortedScripts (scriptEditor scripter)) {
		op = (primName (expression aBlock))
		if ('nop' != op) {
			saveChunk this aBlock
		}
	}
}

method saveChunk SmallRuntime aBlock {
	// Save the script starting with the given block as an executable code "chunk".
	// Also save the source code (in GP format) and the script position.

	// save the binary code for the chunk
	chunkID = (chunkIdFor this aBlock)
	chunkType = (chunkTypeForBlock this aBlock)
	data = (list chunkType)
	addAll data (chunkBytesForBlock this aBlock)
	sendMsg this 'chunkCodeMsg' chunkID data
	waitMSecs ((count data) / 10) // wait approximate transmission time

return // xxx do not save source code for now; it can overwhealm serial connection

	// save the GP source code
	data = (list 2) // GP source code attribute
	addAll data (toArray (toBinaryData (toTextCode aBlock)))
	if ((count data) > 1000) {
		print 'Source code too big; not saving:' (count data) 'bytes'
		return
	}
	sendMsg this 'chunkAttributeMsg' chunkID data

	// save the script position (relative to its owner)
	posX = ((left (morph aBlock)) - (left (owner (morph aBlock))))
	posY = ((top (morph aBlock)) - (top (owner (morph aBlock))))
	data = (list 0) // source position attribute
	addAll data (list (posX & 255) ((posX >> 8) & 255) (posY & 255) ((posY >> 8) & 255))
	sendMsg this 'chunkAttributeMsg' chunkID data
}

method runChunk SmallRuntime chunkID {
	sendMsg this 'startChunkMsg' chunkID
}

method stopRunningChunk SmallRuntime chunkID {
	sendMsg this 'stopChunkMsg' chunkID
}

method getVar SmallRuntime varID {
	if (isNil varID) { varID = 0 }
	sendMsg this 'getVarMsg' varID
}

// Message handling

method msgNameToID SmallRuntime msgName {
	if (isNil msgDict) {
		msgDict = (dictionary)
		atPut msgDict 'chunkCodeMsg' 1
		atPut msgDict 'deleteChunkMsg' 2
		atPut msgDict 'startChunkMsg' 3
		atPut msgDict 'stopChunkMsg' 4
		atPut msgDict 'startAllMsg' 5
		atPut msgDict 'stopAllMsg' 6
		atPut msgDict 'getVarMsg' 7
		atPut msgDict 'setVarMsg' 8
		atPut msgDict 'deleteVarMsg' 10
		atPut msgDict 'deleteCommentMsg' 11
		atPut msgDict 'getVersionMsg' 12
		atPut msgDict 'getAllCodeMsg' 13
		atPut msgDict 'deleteAllCodeMsg' 14
		atPut msgDict 'systemResetMsg' 15
		atPut msgDict 'taskStartedMsg' 16
		atPut msgDict 'taskDoneMsg' 17
		atPut msgDict 'taskReturnedValueMsg' 18
		atPut msgDict 'taskErrorMsg' 19
		atPut msgDict 'outputValueMsg' 20
		atPut msgDict 'varValueMsg' 21
		atPut msgDict 'versionMsg' 22
		atPut msgDict 'pingMsg' 26
		atPut msgDict 'broadcastMsg' 27
		atPut msgDict 'chunkAttributeMsg' 28
		atPut msgDict 'varNameMsg' 29
		atPut msgDict 'commentMsg' 30
		atPut msgDict 'commentPositionMsg' 31
	}
	msgType = (at msgDict msgName)
	if (isNil msgType) { error 'Unknown message:' msgName }
	return msgType
}

method errorString SmallRuntime errID {
	// Return an error string for the given errID from error definitions copied and pasted from interp.h

	defsFromHeaderFile = '
#define noError					0	// No error
#define unspecifiedError		1	// Unknown error
#define badChunkIndexError		2	// Unknown chunk index

#define insufficientMemoryError	10	// Insufficient memory to allocate object
#define needsArrayError			11	// Needs an Array or ByteArray
#define needsBooleanError		12	// Needs a boolean
#define needsIntegerError		13	// Needs an integer
#define needsStringError		14	// Needs a string
#define nonComparableError		15	// Those objects cannot be compared for equality
#define arraySizeError			16	// Array size must be a non-negative integer
#define needsIntegerIndexError	17	// Array index must be an integer
#define indexOutOfRangeError	18	// Array index out of range
#define byteArrayStoreError		19 	// A ByteArray can only store integer values between 0 and 255
#define hexRangeError			20	// Hexadecimal input must between between -1FFFFFFF and 1FFFFFFF
#define i2cDeviceIDOutOfRange	21	// I2C device ID must be between 0 and 127
#define i2cRegisterIDOutOfRange	22	// I2C register must be between 0 and 255
#define i2cValueOutOfRange		23	// I2C value must be between 0 and 255
#define notInFunction			24	// Attempt to access an argument outside of a function
#define badForLoopArg			25	// for-loop argument must be a positive integer, array, or bytearray
#define stackOverflow			26	// Insufficient stack space
'
	for line (lines defsFromHeaderFile) {
		words = (words line)
		if (and ((count words) > 2) ('#define' == (first words))) {
			if (errID == (toInteger (at words 3))) {
				msg = (joinStrings (copyFromTo words 5) ' ')
				return (join 'Error: ' msg)
			}
		}
	}
	return (join 'Unknown error: ' errID)
}

method sendMsg SmallRuntime msgName chunkID byteList {
	if (isNil chunkID) { chunkID = 0 }
	msgID = (msgNameToID this msgName)
	if (isNil byteList) { // short message
		msg = (list 250 msgID chunkID)
	} else { // long message
		byteCount = ((count byteList) + 1)
		msg = (list 251 msgID chunkID (byteCount & 255) ((byteCount >> 8) & 255))
		addAll msg byteList
		add msg 254 // terminator byte (helps board detect dropped bytes)
	}
	ensurePortOpen this
	writeSerialPort port (toBinaryData (toArray msg))
}

method ensurePortOpen SmallRuntime {
	if (or (isNil port) (not (isOpenSerialPort port))) {
		if (notNil portName) {
			port = (openSerialPort portName 115200)
		}
	}
}

method processMessages SmallRuntime {
	if (or (isNil port) (not (isOpenSerialPort port))) { return }
	if (isNil recvBuf) { recvBuf = (newBinaryData 0) }
	repeat 20 { processMessages2 this }
}

method processMessages2 SmallRuntime {
// showOutputStrings this
// return // xxx

// s = (readSerialPort port)
// if (notNil s) { print s } // print raw debug strings from VM
// return // xxx

// s = (readSerialPort port true)
// if (notNil s) { print (toArray s) } // print message bytes
// return // xxx

	// Read any available bytes and append to recvBuf
	s = (readSerialPort port true)
	if (notNil s) { recvBuf = (join recvBuf s) }
	if ((byteCount recvBuf) < 3) { return } // incomplete message

	// Parse and dispatch messages
	firstByte = (byteAt recvBuf 1)
	if (250 == firstByte) { // short message
		handleMessage this (copyFromTo recvBuf 1 3)
		recvBuf = (copyFromTo recvBuf 4) // remove message
	} (251 == firstByte) { // long message
		if ((byteCount recvBuf) < 5) { return } // incomplete length field
		bodyBytes = (((byteAt recvBuf 5) << 8) | (byteAt recvBuf 4))
		if ((byteCount recvBuf) < (5 + bodyBytes)) { return } // incomplete body
		handleMessage this (copyFromTo recvBuf 1 (bodyBytes + 5))
		recvBuf = (copyFromTo recvBuf (bodyBytes + 6)) // remove message
	} else {
		print 'Bad message header byte; should be 250 or 251 but is:' firstByte
		recvBuf = (newBinaryData 0) // discard
	}
}

method handleMessage SmallRuntime msg {
	op = (byteAt msg 2)
	if (op == (msgNameToID this 'taskStartedMsg')) {
		updateRunning this (byteAt msg 3) true
	} (op == (msgNameToID this 'taskDoneMsg')) {
		updateRunning this (byteAt msg 3) false
	} (op == (msgNameToID this 'taskReturnedValueMsg')) {
		chunkID = (byteAt msg 3)
		showResult this chunkID (returnedValue this msg)
		updateRunning this chunkID false
	} (op == (msgNameToID this 'taskErrorMsg')) {
		chunkID = (byteAt msg 3)
		showResult this chunkID (errorString this (byteAt msg 6))
		updateRunning this (byteAt msg 3) false
	} (op == (msgNameToID this 'outputValueMsg')) {
		chunkID = (byteAt msg 3)
		if (chunkID == 255) {
			print (returnedValue this msg)
		} else {
			showResult this chunkID (returnedValue this msg)
		}
	} (op == (msgNameToID this 'varValueMsg')) {
		print 'variable value:' (returnedValue this msg)
	} (op == (msgNameToID this 'versionMsg')) {
		showVersion this (returnedValue this msg)
	} (op == (msgNameToID this 'pingMsg')) {
		lastPingRecvMSecs = (msecsSinceStart)
	} (op == (msgNameToID this 'broadcastMsg')) {
//		print 'received broadcast:' (toString (copyFromTo msg 6))
	} (op == (msgNameToID this 'chunkCodeMsg')) {
//		print 'chunkCodeMsg:' (byteCount msg) 'bytes'
	} (op == (msgNameToID this 'chunkAttributeMsg')) {
//		print 'chunkAttributeMsg:' (byteCount msg) 'bytes'
	} else {
		print 'msg:' (toArray msg)
	}
}

method updateRunning SmallRuntime chunkID runFlag {
	if (isNil chunkRunning) {
		chunkRunning = (newArray 256 false)
	}
	atPut chunkRunning (chunkID + 1) runFlag
	updateHighlights this
}

method isRunning SmallRuntime aBlock {
	if (isNil chunkRunning) { return false }
	return (at chunkRunning ((chunkIdFor this aBlock) + 1))
}

method allStopped SmallRuntime {
	chunkRunning = (newArray 256 false) // clear all running flags
	updateHighlights this
}

method updateHighlights SmallRuntime {
	scale = (global 'scale')
	for m (parts (morph (scriptEditor scripter))) {
		if (isClass (handler m) 'Block') {
			if (isRunning this (handler m)) {
				addHighlight m (4 * scale)
			} else {
				removeHighlight m
			}
		}
	}
}

method showResult SmallRuntime chunkID value {
	for m (join
			(parts (morph (scriptEditor scripter)))
			(parts (morph (blockPalette scripter)))) {
		h = (handler m)
		if (and (isClass h 'Block') (chunkID == (lookupChunkID this h))) {
			showHint m value
		}
	}
}

method returnedValue SmallRuntime msg {
	type = (byteAt msg 6)
	if (1 == type) {
		return (+ ((byteAt msg 10) << 24) ((byteAt msg 9) << 16) ((byteAt msg 8) << 8) (byteAt msg 7))
	} (2 == type) {
		return (toString (copyFromTo msg 7))
	} (3 == type) {
		return (0 != (byteAt msg 7))
	} (4 == type) {
		return (toArray (copyFromTo msg 7))
	} else {
		return (join 'unknown type: ' type)
	}
}

method showOutputStrings SmallRuntime {
	// For debuggong. Just display incoming characters.
	if (isNil port) { return }
	s = (readSerialPort port)
	if (notNil s) {
		if (isNil recvBuf) { recvBuf = '' }
		recvBuf = (toString recvBuf)
		recvBuf = (join recvBuf s)
		while (notNil (findFirst recvBuf (newline))) {
			i = (findFirst recvBuf (newline))
			out = (substring recvBuf 1 (i - 2))
			recvBuf = (substring recvBuf (i + 1))
			print out
		}
	}
}

// testing

method broadcastTest SmallRuntime {
	msg = 'go!'
	sendMsg this 'broadcastMsg' 0 (toArray (toBinaryData msg))
}

method setVarTest SmallRuntime {
	val = 'foobar'
	varID = 0
	body = nil
	if (isClass val 'Integer') {
		body = (newBinaryData 5)
		byteAtPut body 1 1 // type 1 - Integer
		byteAtPut body 2 (val & 255)
		byteAtPut body 3 ((val >> 8) & 255)
		byteAtPut body 4 ((val >> 16) & 255)
		byteAtPut body 5 ((val >> 24) & 255)
	} (isClass val 'String') {
		body = (toBinaryData (join (string 2) val))
	} (isClass val 'Boolean') {
		body = (newBinaryData 2)
		byteAtPut body 1 3 // type 3 - Boolean
		if val {
			byteAtPut body 2 1 // true
		} else {
			byteAtPut body 2 0 // false
		}
	}
	if (notNil body) { sendMsg this 'setVarMsg' 0 (toArray body) }
}

method getCodeTest SmallRuntime {
	sendMsg this 'getAllCodeMsg'
}
