// LegacyNames.cpp
//
// Decoding file names that are not UTF-8. Kept apart from the rest of the bridge so
// that CoreFoundation's headers and 7-Zip's Windows-style ones never meet.

#include <CoreFoundation/CoreFoundation.h>

#include <cstring>
#include <string>

namespace SZBridge {

bool DecodeLegacyName(const std::string &bytes, unsigned codePage, std::string &utf8) {
    const CFStringEncoding encoding = CFStringConvertWindowsCodepageToEncoding(codePage);
    if (encoding == kCFStringEncodingInvalidId || !CFStringIsEncodingAvailable(encoding)) return false;

    CFStringRef string = CFStringCreateWithBytes(kCFAllocatorDefault,
                                                 reinterpret_cast<const UInt8 *>(bytes.data()),
                                                 static_cast<CFIndex>(bytes.size()), encoding, false);
    if (!string) return false;

    const CFIndex capacity = CFStringGetMaximumSizeForEncoding(CFStringGetLength(string), kCFStringEncodingUTF8) + 1;
    std::string buffer(static_cast<size_t>(capacity), '\0');
    const Boolean converted = CFStringGetCString(string, &buffer[0], capacity, kCFStringEncodingUTF8);
    CFRelease(string);
    if (!converted) return false;

    buffer.resize(std::strlen(buffer.c_str()));
    utf8 = buffer;
    return true;
}

}  // namespace SZBridge
