//
//  AirScreen-Bridging-Header.h
//  AirScreen
//
//  FairPlay (PlayFair) decryption - ported from RPiPlay
//

#ifndef AirScreen_Bridging_Header_h
#define AirScreen_Bridging_Header_h

// PlayFair: FairPlay SAP key decryption
// message3 = 164-byte FP Phase 2 body from iOS device
// cipherText = 72-byte ekey from SETUP
// keyOut = 16-byte decrypted AES key (output)
void playfair_decrypt(unsigned char* message3, unsigned char* cipherText, unsigned char* keyOut);

#endif /* AirScreen_Bridging_Header_h */
