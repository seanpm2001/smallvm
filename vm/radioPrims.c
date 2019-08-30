/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// Copyright 2019 John Maloney, Bernat Romagosa, and Jens Mönig

// radioPrims.cpp - Primitives for the BBC micro:bit radio
// John Maloney, February 2019

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "mem.h"
#include "interp.h"

// MakeCode Packet Types

#define MAKECODE_PACKET_INTEGER 0
#define MAKECODE_PACKET_PAIR 1
#define MAKECODE_PACKET_STRING 2
#define MAKECODE_PACKET_DOUBLE 4
#define MAKECODE_PACKET_DOUBLE_PAIR 5

// Variables

static int radioSignalStrength = -999;
static int receivedMessageType = -1;
static int receivedInteger = 0;

struct {
	uint32 header;
	char body[32];
} receivedString; // static string OBJ containing string from most recent message

struct {
	uint32 header;
	char body[20];
} messageTypeString; // Static string OBJ containing MakeCode type of most recent message

#if defined(ARDUINO_BBC_MICROBIT)

#include <nrf51.h>
#include <nrf51_bitfields.h>

#define PACKET_SIZE 32
#define MAX_PACKETS 4 // number of packets in the receive buffer; must be a power of 2
static uint8_t receiveBuffer[MAX_PACKETS * PACKET_SIZE];

static uint8_t radioInitialized = false;
static uint8_t receivedPacketCount = 0;
static uint8_t packetIndex = 0; // index of current packet buffer (0..(MAX_PACKETS - 1)

// Radio Setup

static void startReceiving() {
	// Enable receive mode
	NRF_RADIO->EVENTS_READY = 0;
	NRF_RADIO->TASKS_RXEN = 1;
	while (NRF_RADIO->EVENTS_READY == 0);

	// Start receiving
	NRF_RADIO->EVENTS_END = 0;
	NRF_RADIO->TASKS_START = 1;

	// Enable receive interrupts
	NVIC_ClearPendingIRQ(RADIO_IRQn);
	NVIC_EnableIRQ(RADIO_IRQn);
}

static void disableRadio() {
	NVIC_DisableIRQ(RADIO_IRQn);
	NRF_RADIO->EVENTS_DISABLED = 0;
	NRF_RADIO->TASKS_DISABLE = 1;
	while (NRF_RADIO->EVENTS_DISABLED == 0);
}

static void initializeRadio() {
	// Set up the Nordic radio for peer-to-peer communication.
	// The radio configuration is interoperable with the micro:bit DAL radio commands.

	if (radioInitialized) return;

	// start high-frequency clock, needed by the radio
	NRF_CLOCK->EVENTS_HFCLKSTARTED = 0;
	NRF_CLOCK->TASKS_HFCLKSTART = 1;
	while (NRF_CLOCK->EVENTS_HFCLKSTARTED == 0);

	// start radio with default power, frequency, and bitrate.
	NRF_RADIO->TXPOWER = 0;
	NRF_RADIO->FREQUENCY = 7;
	NRF_RADIO->MODE = RADIO_MODE_MODE_Nrf_1Mbit;

	// Use micro:bit DAL/MakeCode addressing scheme:
	// All devices use the same 32-bit base address (ASCII "uBit"). The full 400bit address
	// combines base address with an 8-bit "group" ID. All micro:bits with the same group ID
	// receive each other's broadcasts.
	NRF_RADIO->BASE0 = 0x75626974;
	NRF_RADIO->PREFIX0 = (uint32_t) 0; // default to group 0
	NRF_RADIO->TXADDRESS = 0;
	NRF_RADIO->RXADDRESSES = 1;

	// packet layout settings:
	NRF_RADIO->PCNF0 = 0x00000008; // no S0 or S1 fields, 8-bit length field
	NRF_RADIO->PCNF1 = 0x02040000 | PACKET_SIZE; // enable whitening, 4-byte base address, max packet size

	// use 16bit CRC; exclude address from CRC
	NRF_RADIO->CRCCNF = RADIO_CRCCNF_LEN_Two;
	NRF_RADIO->CRCINIT = 0xFFFF;
	NRF_RADIO->CRCPOLY = 0x11021;

	// random seed for data whitening algorithm (must be non-zero)
	NRF_RADIO->DATAWHITEIV = 0x18;

	// issue interrupt when a task completes (e.g. send/receive)
	NRF_RADIO->INTENSET = 0x00000008;
	NRF_RADIO->SHORTS |= RADIO_SHORTS_ADDRESS_RSSISTART_Msk;

	// set pointer to receive buffer for DMA
	NRF_RADIO->PACKETPTR = (uint32_t) receiveBuffer;

	startReceiving();
	radioInitialized = true;
}

// Radio Interrupt Handler

void RADIO_IRQHandler(void) {
	if (NRF_RADIO->EVENTS_READY) {
		// READY event: start the receiver and wait for the END event

		NRF_RADIO->EVENTS_READY = 0;
		NRF_RADIO->TASKS_START = 1;
	}
	if (NRF_RADIO->EVENTS_END) {
		// END event: a packet has been received

		NRF_RADIO->EVENTS_END = 0;
		if (NRF_RADIO->CRCSTATUS == 1) {
			int sample = (int) NRF_RADIO->RSSISAMPLE; // RSSI for this packet
			radioSignalStrength = -sample;

			if (receivedPacketCount < MAX_PACKETS) receivedPacketCount++;
			packetIndex = (packetIndex + 1) % MAX_PACKETS; // receive into next packet buffer
			NRF_RADIO->PACKETPTR = (uint32_t) &receiveBuffer[packetIndex * PACKET_SIZE];
		} else { // bad CRC; ignore this packet
			radioSignalStrength = 0;
		}

		// restart the receiver
		NRF_RADIO->TASKS_START = 1;
	}
}

// Radio Functions

static void setGroup(int groupID) {
	// Set our radio group ID (0-255). Receive only packets with this groupID.

	if ((groupID < 0) || (groupID > 255)) return;
	if (!radioInitialized) initializeRadio();
	NRF_RADIO->PREFIX0 = (uint32_t) groupID;
}

static void setPower(int level) {
	// Set the transmit power level (0-7) using the micro:bit DAL power level scheme.

	const int8_t powerLevels[] = {-30, -20, -16, -12, -8, -4, 0, 4};

	if ((level < 0) || (level > 7)) return;
	if (!radioInitialized) initializeRadio();
	NRF_RADIO->TXPOWER = (uint32_t) powerLevels[level];
}

static void setChannel(int channel) {
	// Set the radio channe (center frequency). The argument (0-83) maps to frequencies
	// 2400 to 2483 MHz in 1 MHz increments.

	if ((channel < 0) || (channel > 83)) return;
	if (!radioInitialized) initializeRadio();

	disableRadio(); // must turn off radio to change channel
	NRF_RADIO->FREQUENCY = (uint32_t) channel;
	startReceiving();
}

static int receivePacket(uint8_t *packet) {
	if (!radioInitialized) initializeRadio();
	if (receivedPacketCount <= 0) return false;

	int readIndex = (packetIndex - receivedPacketCount) & (MAX_PACKETS - 1);
	memcpy(packet, &receiveBuffer[readIndex * PACKET_SIZE], 32);
	receivedPacketCount--;

	return true;
}

static void sendPacket(uint8_t *packet) {
	// Transmit the given 32-byte packet. Block until transmisson is complete.
	// Note: The radio can do only one thing at at time; we need to stop receiving to transmit.

	if (packet == NULL) return;

	if (!radioInitialized) initializeRadio();
	disableRadio();

	// set the transmit packet
	NRF_RADIO->PACKETPTR = (uint32_t) packet;

	// switch to transmit mode
	NRF_RADIO->EVENTS_READY = 0;
	NRF_RADIO->TASKS_TXEN = 1;
	while (NRF_RADIO->EVENTS_READY == 0);

	// start transmission and wait until packet has been sent
	NRF_RADIO->EVENTS_END = 0;
	NRF_RADIO->TASKS_START = 1;

	while (NRF_RADIO->EVENTS_END == 0);

	// restore the receive packet
	NRF_RADIO->PACKETPTR = (uint32_t) &receiveBuffer[packetIndex * PACKET_SIZE];

	disableRadio();  // disable the transmitter
	startReceiving();
}

static int receiveMakeCodeMessage() {
	// Read the next incoming packet, if any. If a packet is received and it is a MakeCode
	// message, extract the data from it and return true. Otherwise, return false.

	uint8_t packet[32];

	if (!radioInitialized) initializeRadio();
	if (!receivePacket(packet)) return false; // no packet received

	int len = packet[0];
	if ((len < 12) || (1 != packet[1]) || (1 != packet[3])) return false; // not a MakeCode packet

	// clear old received values
	receivedInteger = 0;
	receivedString.body[0] = '\0';
	char *src;
	int maxStringLen;
	int stringLength = 0;
	double dbl;

	receivedMessageType = packet[4];
	if (MAKECODE_PACKET_INTEGER == receivedMessageType) { // integer
		receivedInteger = (packet[16] << 24) | (packet[15] << 16) | (packet[14] << 8) | packet[13];
	} else if (MAKECODE_PACKET_PAIR == receivedMessageType) { // string-integer pair
		receivedInteger = (packet[16] << 24) | (packet[15] << 16) | (packet[14] << 8) | packet[13];
		stringLength = packet[17];
		src = (char *) &packet[18];
		maxStringLen = 32 - 18;
	} else if (MAKECODE_PACKET_STRING == receivedMessageType) { // string
		stringLength = packet[13];
		src = (char *) &packet[14];
		maxStringLen = 32 - 14;
	} else if (MAKECODE_PACKET_DOUBLE == receivedMessageType) { // double
		memcpy(&dbl, &packet[13], sizeof(dbl));
		receivedInteger = (int) rint(dbl);
	} else if (MAKECODE_PACKET_DOUBLE_PAIR == receivedMessageType) { // string-double pair
		memcpy(&dbl, &packet[13], sizeof(dbl));
		receivedInteger = (int) rint(dbl);
		stringLength = packet[21];
		src = (char *) &packet[22];
		maxStringLen = 32 - 21;
	}

	// copy string into receivedString
	if (stringLength > 19) stringLength = 19;
	for (int i = 0; i < stringLength; i++) receivedString.body[i] = *src++;
	receivedString.body[stringLength] = '\0'; // null terminator
	receivedString.header = HEADER(StringClass, (stringLength + 4) / 4);

	return true;
}

static int initMakeCodePacket(uint8_t *packet, int makeCodePacketType, int packetLength) {
	uint32 timestamp = millisecs();
	uint32 id = NRF_FICR->DEVICEID[1];

	packet[0] = packetLength;
	packet[1] = 1; // protocol
	packet[2] = 0; // group (always 0)
	packet[3] = 1; // version
	packet[4] = makeCodePacketType;

	// 4-byte timestamp, LSB byte order
	packet[5] = timestamp & 255;
	packet[6] = (timestamp >> 8) & 255;
	packet[7] = (timestamp >> 16) & 255;
	packet[8] = (timestamp >> 24) & 255;

	// 4-byte micro:bit ID, LSB byte order
	packet[9] = id & 255;
	packet[10] = (id >> 8) & 255;
	packet[11] = (id >> 16) & 255;
	packet[12] = (id >> 24) & 255;
}

// primitives

static OBJ primDisableRadio(int argCount, OBJ *args) {
	if (radioInitialized) disableRadio();
	radioInitialized = false;
}

static OBJ primMessageReceived(int argCount, OBJ *args) {
	return receiveMakeCodeMessage() ? trueObj : falseObj;
}

static OBJ primPacketReceive(int argCount, OBJ *args) {
	// If a packet has been received, copy it into supplied 32 element list and return true.
	// Otherwise, return false.

	if ((argCount > 0) && IS_CLASS(args[0], ArrayClass) && WORDS(args[0]) >= 32) {
		OBJ arg0 = args[0];
		uint8_t packet[32];
		int gotData = receivePacket(packet);
		if (!gotData) return falseObj; // no packet received
		int packetLen = packet[0];
		for (int i = 0; i < 32; i++) {
			FIELD(arg0, i) = (i <= packetLen) ? int2obj(packet[i]) : int2obj(0);
		}
		return trueObj;
	}
	return falseObj;
}

static OBJ primPacketSend(int argCount, OBJ *args) {
	// Send the given 32-element list as a 32-byte packet.

	if ((argCount > 0) && IS_CLASS(args[0], ArrayClass) && WORDS(args[0]) >= 32) {
		OBJ arg0 = args[0];
		uint8_t packet[32];
		for (int i = 0; i < 32; i++) {
			OBJ item = FIELD(arg0, i);
			packet[i] = isInt(item) ? obj2int(item) : 0;
		}
		sendPacket(packet);
	}
}

static OBJ primSendMakeCodeInteger(int argCount, OBJ *args) {
	if ((argCount > 0) && isInt(args[0])) {
		int n = obj2int(args[0]);
		uint8_t packet[32];
		initMakeCodePacket(packet, MAKECODE_PACKET_INTEGER, 16);
		packet[13] = n & 255;
		packet[14] = (n >> 8) & 255;
		packet[15] = (n >> 16) & 255;
		packet[16] = (n >> 24) & 255;
		sendPacket(packet);
	}
}

static OBJ primSendMakeCodePair(int argCount, OBJ *args) {
	if ((argCount > 1) && IS_CLASS(args[0], StringClass) && isInt(args[1])) {
		char *s = obj2str(args[0]);
		int n = obj2int(args[1]);
		int len = strlen(s);
		if (len > 14) len = 14;
		uint8_t packet[32];
		initMakeCodePacket(packet, MAKECODE_PACKET_PAIR, 17 + len);
		packet[13] = n & 255;
		packet[14] = (n >> 8) & 255;
		packet[15] = (n >> 16) & 255;
		packet[16] = (n >> 24) & 255;
		packet[17] = len;
		for (int i = 0; i < len; i++) {
			packet[18 + i] = s[i];
		}
		sendPacket(packet);
	}
}

static OBJ primSendMakeCodeString(int argCount, OBJ *args) {
	if ((argCount > 0) && IS_CLASS(args[0], StringClass)) {
		char *s = obj2str(args[0]);
		int len = strlen(s);
		if (len > 18) len = 18;
		uint8_t packet[32];
		initMakeCodePacket(packet, MAKECODE_PACKET_STRING, 13 + len);
		packet[13] = len;
		for (int i = 0; i < len; i++) {
			packet[14 + i] = s[i];
		}
		sendPacket(packet);
	}
}

static OBJ primSetChannel(int argCount, OBJ *args) {
	if ((argCount > 0) && isInt(args[0])) {
		setChannel(obj2int(args[0]));
	}
}

static OBJ primSetGroup(int argCount, OBJ *args) {
	if ((argCount > 0) && isInt(args[0])) {
		setGroup(obj2int(args[0]));
	}
}

static OBJ primSetPower(int argCount, OBJ *args) {
	if ((argCount > 0) && isInt(args[0])) {
		setPower(obj2int(args[0]));
	}
}

#else // not micro:bit

// stubs

static OBJ primDisableRadio(int argCount, OBJ *args) { return falseObj; }
static OBJ primMessageReceived(int argCount, OBJ *args) { return falseObj; }
static OBJ primPacketReceive(int argCount, OBJ *args) { return falseObj; }
static OBJ primPacketSend(int argCount, OBJ *args) { return falseObj; }
static OBJ primSendMakeCodeInteger(int argCount, OBJ *args) { return falseObj; }
static OBJ primSendMakeCodePair(int argCount, OBJ *args) { return falseObj; }
static OBJ primSendMakeCodeString(int argCount, OBJ *args) { return falseObj; }
static OBJ primSetChannel(int argCount, OBJ *args) { return falseObj; }
static OBJ primSetGroup(int argCount, OBJ *args) { return falseObj; }
static OBJ primSetPower(int argCount, OBJ *args) { return falseObj; }

#endif

static OBJ primReceivedInteger() {
	return int2obj(receivedInteger);
}

static OBJ primReceivedMessageType(int argCount, OBJ *args) {
	char *s = "other";
	if (-1 == receivedMessageType) s = "none";
	if (MAKECODE_PACKET_INTEGER == receivedMessageType) s = "number";
	if (MAKECODE_PACKET_PAIR == receivedMessageType) s = "pair";
	if (MAKECODE_PACKET_STRING == receivedMessageType) s = "string";
	if (MAKECODE_PACKET_DOUBLE == receivedMessageType) s = "number";
	if (MAKECODE_PACKET_DOUBLE_PAIR == receivedMessageType) s = "pair";

	// return non-heap string object to avoid using up heap space
	strcpy(messageTypeString.body, s);
	messageTypeString.header = HEADER(StringClass, (strlen(s) + 4) / 4);
	return (OBJ) &messageTypeString;
}

static OBJ primReceivedString() {
	return (OBJ) &receivedString;
}

static OBJ primSignalStrength(int argCount, OBJ *args) {
	// Return the signal strength (RSSI) of the most recently received packet.
	// Values are negative, with higher values for stronger signals.

	return int2obj(radioSignalStrength);
}

static PrimEntry entries[] = {
	"disableRadio", primDisableRadio,
	"messageReceived", primMessageReceived,
	"packetReceive", primPacketReceive,
	"packetSend", primPacketSend,
	"receivedInteger", primReceivedInteger,
	"receivedMessageType", primReceivedMessageType,
	"receivedString", primReceivedString,
	"sendInteger", primSendMakeCodeInteger,
	"sendPair", primSendMakeCodePair,
	"sendString", primSendMakeCodeString,
	"setChannel", primSetChannel,
	"setGroup", primSetGroup,
	"setPower", primSetPower,
	"signalStrength", primSignalStrength,
};

void addRadioPrims() {
	addPrimitiveSet("radio", sizeof(entries) / sizeof(PrimEntry), entries);
}
