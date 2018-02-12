// MicroBlocksPatches.gp - This file patches/replaces methods in GP's normal class library
// with versions that support MicroBlocks (possibly making them no longer work correctly in
// the normal GP IDE.
//
// This file must be processed *after* the normal GP library has been read with a command like:
//
//	./gp runtime/lib/* microBlocks/GP-IDE/* -
//
// John Maloney, January, 2018

method clicked Block hand {
  runtime = (smallRuntime)
  topBlock = (topBlock this)
  if (isRunning runtime topBlock) {
	stopRunningChunk runtime (chunkIdFor runtime topBlock)
  } else {
	evalOnBoard runtime topBlock
  }
}

method contextMenu Block {
  if (isPrototype this) {return nil}
  menu = (menu nil this)
// MicroBlocks menu additions:
addItem menu 'show instructions' (action 'showInstructions' (smallRuntime) this)
addItem menu 'show compiled bytes' (action 'evalOnBoard' (smallRuntime) this true)
addLine menu

  isInPalette = ('template' == (grabRule morph))
  if (isVariadic this) {
    if (canExpand this) {addItem menu 'expand' 'expand'}
    if (canCollapse this) {addItem menu 'collapse' 'collapse'}
    addLine menu
  }
  if (and isInPalette (isRenamableVar this)) {
    addItem menu 'rename...' 'userRenameVariable'
    addLine menu
  }
  addItem menu 'duplicate' 'grabDuplicate' 'just this one block'
  if (and ('reporter' != type) (notNil (next this))) {
    addItem menu '...all' 'grabDuplicateAll' 'duplicate including all attached blocks'
  }
//  addItem menu 'copy to clipboard' 'copyToClipboard'

  if (not isInPalette) {
    addLine menu
    addItem menu 'delete' 'delete'
  }
  return menu
}

method okayToBeDestroyedByUser Block {
  if (isPrototypeHat this) {
	editor = (findProjectEditor)
	if (isNil editor) { return false }
    function = (function (first (inputs this)))
    if (confirm (global 'page') nil 'Are you sure you want to remove this block definition?') {
	  removedUserDefinedBlock (scripter editor) function
	  deleteChunkForBlock (smallRuntime) this
      return true
    }
    return false
  }
  deleteChunkForBlock (smallRuntime) this
  return true
}

method contextMenu ScriptEditor {
  menu = (menu nil this)
  addItem menu 'clean up' 'cleanUp' 'arrange scripts'
  if (and (notNil lastDrop) (isRestorable lastDrop)) {
    addItem menu 'undrop' 'undrop' 'undo last drop'
  }
  return menu
}

method blockColorForCategory AuthoringSpecs cat {
  defaultColor = (color 4 148 220)
  if (isOneOf cat 'Control' 'Functions') {
	if (notNil (global 'controlColor')) { return (global 'controlColor') }
	return (color 230 168 34)
  } ('Variables' == cat) {
	if (notNil (global 'variableColor')) { return (global 'variableColor') }
	return (color 243 118 29)
  } (isOneOf cat 'Operators' 'Math') {
	if (notNil (global 'operatorsColor')) { return (global 'operatorsColor') }
	return (color 98 194 19)
  } ('Obsolete' == cat) {
	return (color 196 15 0)
  }
  if (notNil (global 'defaultColor')) { return (global 'defaultColor') }
  return defaultColor
}

method clear AuthoringSpecs {
  specsList = (list)
  specsByOp = (dictionary)
  opCategory = (dictionary)
  return this
}

method fixLayout Block {
  space = 3
  vSpace = 3

  break = 450
  lineHeights = (list)
  lines = (list)
  lineArgCount = 0

  left = (left morph)
  blockWidth = 0
  blockHeight = 0
  h = 0
  w = 0

  if (global 'stealthBlocks') {
    if (type == 'hat') {
      indentation = (stealthLevel (* scale (+ border space)) 0)
    } (type == 'reporter') {
      indentation = (stealthLevel (* scale rounding) (width (stealthText this '(')))
    } (type == 'command') {
      indentation = (stealthLevel (* scale (+ border inset dent (corner * 2))) 0)
    }
  } else {
    if (type == 'hat') {
      indentation = (* scale (+ border space))
    } (type == 'reporter') {
      indentation = (* scale rounding)
    } (type == 'command') {
      indentation = (* scale (+ border inset dent (corner * 2)))
    }
  }

  // arrange label parts horizontally and break up into lines
  currentLine = (list)
  for group labelParts {
    for each group {
      if (isVisible (morph each)) {
        if (isClass each 'CommandSlot') {
          add lines currentLine
          add lineHeights h
          setLeft (morph each) (+ left (* scale (+ border corner)))
          add lines (list each)
          add lineHeights (height (morph each))
          currentLine = (list)
          w = 0
          h = 0
        } else {
          x = (+ left indentation w)
          w += (width (fullBounds (morph each)))
          w += (space * scale)
          if (and ('mbDisplay' == (primName expression)) (each == (first group))) {
			lineArgCount = 10; // force a line break after first item of 'mbDisplay' block
          }
          if (and (or (w > (break * scale)) (lineArgCount >= 5)) (notEmpty currentLine)) {
            add lines currentLine
            add lineHeights h
            currentLine = (list)
            h = 0
            x = (+ left indentation)
            w = ((width (fullBounds (morph each))) + (space * scale))
            lineArgCount = 0
          }
          add currentLine each
          h = (max h (height (morph each)))
          setLeft (morph each) x
		  if (not (isClass each 'Text')) { lineArgCount += 1 }
        }
      }
    }
  }

  // add the block drawer, if any
  drawer = (drawer this)
  if (notNil drawer) {
    x = (+ left indentation w)
    w += (width (fullBounds (morph drawer)))
    w += (space * scale)
    if (and (w > (break * scale)) (notEmpty currentLine)) {
      add lines currentLine
      add lineHeights h
      currentLine = (list)
      h = 0
      x = (+ left indentation)
      w = ((width (fullBounds (morph drawer))) + (space * scale))
    }
    add currentLine drawer
    h = (max h (height (morph drawer)))
    setLeft (morph drawer) x
  }

  // add last label line
  add lines currentLine
  add lineHeights h

  // purge empty lines
  // to do: prevent empty lines from being added in the first place
  for i (count lines) {
    if (isEmpty (at lines i)) {
      removeAt lines i
      removeAt lineHeights i
    }
  }

  // determine block dimensions from line data
  blockWidth = 0
  for each lines {
    if (notEmpty each) {
      elem = (last each)
      if (not (isClass elem 'CommandSlot')) {
        blockWidth = (max blockWidth ((right (fullBounds (morph elem))) - left))
      }
    }
  }
  blockWidth = (- blockWidth (space * scale))
  blockHeight = (callWith + (toArray lineHeights))
  blockHeight += (* (count lines) vSpace scale)

  // arrange label parts vertically
  if (global 'stealthBlocks') {
    tp = (+ (top morph) (stealthLevel (* 2 scale border) 0))
  } else {
    tp =  (+ (top morph) (* 2 scale border))
  }
  if (type == 'hat') {
    tp += (hatHeight this)
  }
  line = 0
  for eachLine lines {
    line += 1
    bottom = (+ tp (at lineHeights line) (vSpace * scale))
    for each eachLine {
      setYCenterWithin (morph each) tp bottom
    }
    tp = bottom
  }

  // add extra space below the bottom-most c-slot
  extraSpace = 0
  if (and (isNil drawer) (isClass (last (last labelParts)) 'CommandSlot')) {
    extraSpace = (scale * corner)
  }

  // set block dimensions
  blockWidth += (* -1 scale space)
  blockWidth += (* scale border)

  if (global 'stealthBlocks') {
    if (type == 'command') {
      setWidth (bounds morph) (+ blockWidth indentation (stealthLevel (scale * corner) 0))
      setHeight (bounds morph) (stealthLevel (+ blockHeight (* scale corner) (* scale border 4) extraSpace) blockHeight)
    } (type == 'hat') {
      setWidth (bounds morph) (max (scale * (+ hatWidth 20)) (+ blockWidth indentation (stealthLevel (scale * corner) 0)))
      setHeight (bounds morph) (stealthLevel (+ blockHeight (* scale corner 2) (* scale border) (hatHeight this) extraSpace) (+ blockHeight (hatHeight this)))
    } (type == 'reporter') {
      setWidth (bounds morph) (+ blockWidth (2 * indentation) (stealthLevel (scale * rounding) 0))
      setHeight (bounds morph) (stealthLevel (+ blockHeight (* scale border 4) extraSpace) blockHeight)
    }
  } else {
    if (type == 'command') {
      setWidth (bounds morph) (max (scale * 50) (+ blockWidth indentation (scale * corner)))
      setHeight (bounds morph) (+ blockHeight (* scale corner) (* scale border 4) extraSpace)
    } (type == 'hat') {
      setWidth (bounds morph) (max (scale * (+ hatWidth 20)) (+ blockWidth indentation (scale * corner)))
      setHeight (bounds morph) (+ blockHeight (* scale corner 2) (* scale border) (hatHeight this) extraSpace)
    } (type == 'reporter') {
      setWidth (bounds morph) (max (scale * 20) (+ blockWidth indentation (scale * rounding)))
      setHeight (bounds morph) (+ blockHeight (* scale border 4) extraSpace)
    }
  }

  for group labelParts {
    for each group {
      if (isClass each 'CommandSlot') {fixLayout each true}
    }
  }
  redraw this
  nb = (next this)
  if (notNil nb) {
    setPosition (morph nb) (left morph) (- (+ (top morph) (height morph)) (scale * corner))
  }
  raise morph 'layoutChanged' this
}