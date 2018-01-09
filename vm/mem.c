// mem.c - object memory
// Just an allocator for now; no garbage collector.
// John Maloney, April 2017

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mem.h"
#include "interp.h"

static OBJ memStart;
static OBJ freeStart;
static OBJ memEnd;

void memInit(int wordCount) {
	if (sizeof(int) != sizeof(int*)) {
		gpPanic("GP must be compiled in 32-bit mode (e.g. gcc -m32 ...)");
	}
	if (sizeof(int) != sizeof(float)) {
		gpPanic("GP expects floats and ints to be the same size");
	}
	memStart = (OBJ) malloc(wordCount * sizeof(int));
	if (memStart == NULL) {
		gpPanic("memInit failed; insufficient memory");
	}
	if ((unsigned) memStart <= 8) {
		// Reserve object references 0, 4, and 8 for constants nil, true, and false
		// Details: In the unlikely case that memStart <= 8, increment it by 12
		// and reduce wordCount by 3 words.
		memStart = (OBJ) ((unsigned) memStart + 12);
		wordCount -= 3;
	}
	freeStart = memStart;
	memEnd = memStart + wordCount;

	// initialize all global variables to zero
	for (int i = 0; i < MAX_VARS; i++) vars[i] = int2obj(0);
}

void memClear() {
	freeStart = memStart;
}

OBJ newObj(int classID, int wordCount, OBJ fill) {
	OBJ obj = freeStart;
	freeStart += HEADER_WORDS + wordCount;
	if (freeStart >= memEnd) {
		printf("%d words used out of %d\n", freeStart - memStart, memEnd - memStart);
		gpPanic("Out of memory!");
	}
	for (OBJ p = obj; p < freeStart; ) *p++ = (int) fill;
	unsigned header = HEADER(classID, wordCount);
	obj[0] = header;
	return obj;
}

// String Primitives

OBJ newString(char *s) {
	// Create a new string object with the contents of s.
	// Round up to an even number of words and pad with nulls.

	int byteCount = strlen(s) + 1; // leave room for null terminator
	int wordCount = (byteCount + 3) / 4;
	OBJ result = newObj(StringClass, wordCount, 0);
	char *dst = (char *) &result[HEADER_WORDS];
	for (int i = 0; i < byteCount; i++) *dst++ = *s++;
	*dst = 0; // null terminator byte
	return result;
}

char* obj2str(OBJ obj) {
	if (NOT_CLASS(obj, StringClass)) {
		printf("Non-string passed to obj2str()\n");
		return (char *) "";
	}
	return (char *) &obj[HEADER_WORDS];
}

// Debugging

void gpPanic(char *errorMessage) {
	// Called when VM encounters a fatal error. Print the given message and stop.

	printf("\r\n%s\r\n", errorMessage);
	while (true) { } // there's no way to recover; loop forever!
}

void memDumpObj(OBJ obj) {
	if ((obj < memStart) || (obj >= memEnd)) {
		printf("bad object at %ld\n", (long) obj);
		return;
	}
	int classID = CLASS(obj);
	int wordCount = WORDS(obj);
	printf("%x: %d words, classID %d\n", (int) obj, wordCount, classID);
	printf("Header: %x\n", (int) obj[0]);
	for (int i = 0; i < wordCount; i++) printf("	0x%x,\n", obj[HEADER_WORDS + i]);
}