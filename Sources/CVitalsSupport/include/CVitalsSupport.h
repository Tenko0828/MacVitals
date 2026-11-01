#ifndef CVITALS_SUPPORT_H
#define CVITALS_SUPPORT_H
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct VCCollector VCCollector;
VCCollector *VCCreate(void);
void VCDestroy(VCCollector *collector);
CFDictionaryRef VCCopySensors(VCCollector *collector, bool full) CF_RETURNS_RETAINED;
CFArrayRef VCCopyReport(VCCollector *collector) CF_RETURNS_RETAINED;
CFArrayRef VCCopyProcesses(void) CF_RETURNS_RETAINED;
CFArrayRef VCCopyNetworkCounters(void) CF_RETURNS_RETAINED;
CFDictionaryRef VCCopySystemCounts(void) CF_RETURNS_RETAINED;
CFArrayRef VCCopyARMFeatures(void) CF_RETURNS_RETAINED;
#endif
