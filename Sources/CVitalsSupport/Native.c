#include "CVitalsSupport.h"
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <sys/vmmeter.h>
#include <sys/socket.h>
#include <net/if.h>
#include <net/route.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/processor_set.h>
#include <pwd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <math.h>

static CFMutableDictionaryRef dict(void) { return CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks); }
static CFMutableArrayRef array(void) { return CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks); }
static void number(CFMutableDictionaryRef d, CFStringRef k, double v) { CFNumberRef n=CFNumberCreate(NULL,kCFNumberDoubleType,&v); CFDictionarySetValue(d,k,n); CFRelease(n); }
static void integer(CFMutableDictionaryRef d, CFStringRef k, int64_t v) { CFNumberRef n=CFNumberCreate(NULL,kCFNumberSInt64Type,&v); CFDictionarySetValue(d,k,n); CFRelease(n); }
static void string(CFMutableDictionaryRef d, CFStringRef k, const char *v) { CFStringRef s=CFStringCreateWithCString(NULL,v,kCFStringEncodingUTF8); if(s) { CFDictionarySetValue(d,k,s); CFRelease(s); } }
static uint32_t fourcc(const char *s) { return ((uint32_t)(uint8_t)s[0]<<24)|((uint32_t)(uint8_t)s[1]<<16)|((uint32_t)(uint8_t)s[2]<<8)|(uint8_t)s[3]; }

// AppleSMC 的结构使用系统 ABI 默认对齐，不能压紧。
typedef struct { uint8_t major,minor,build,reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version,length; uint32_t cpuPLimit,gpuPLimit,memPLimit; } SMCLimit;
typedef struct { uint32_t size,type; uint8_t attributes; } SMCKeyInfo;
typedef struct { uint32_t key; SMCVersion version; SMCLimit limit; SMCKeyInfo info; uint8_t result,status,command; uint32_t data32; uint8_t bytes[32]; } SMCData;
typedef struct { uint32_t key; SMCKeyInfo info; } CachedKey;
struct VCCollector {
    io_connect_t smc;
    kern_return_t smcStatus;
    CachedKey *keys; size_t keyCount;
    void *iokit, *reportLib;
    CFTypeRef hid;
    CFArrayRef services;
    CFTypeRef subscription;
    CFMutableDictionaryRef channels;
    CFDictionaryRef previous;
    CFTypeRef (*hidCreate)(CFAllocatorRef);
    void (*hidMatch)(CFTypeRef,CFDictionaryRef);
    CFArrayRef (*hidServices)(CFTypeRef);
    CFTypeRef (*hidProperty)(CFTypeRef,CFStringRef);
    CFTypeRef (*hidEvent)(CFTypeRef,int64_t,int32_t,int64_t);
    double (*eventFloat)(CFTypeRef,int);
    CFDictionaryRef (*copyChannels)(CFStringRef,CFStringRef,uint64_t,uint64_t,uint64_t);
    void (*merge)(CFMutableDictionaryRef,CFDictionaryRef,CFTypeRef);
    CFTypeRef (*subscribe)(CFTypeRef,CFMutableDictionaryRef,CFMutableDictionaryRef *,uint64_t,CFTypeRef);
    CFDictionaryRef (*sample)(CFTypeRef,CFMutableDictionaryRef,CFTypeRef);
    CFDictionaryRef (*delta)(CFDictionaryRef,CFDictionaryRef,CFTypeRef);
    int (*iterate)(CFDictionaryRef,int (^)(CFDictionaryRef));
    CFStringRef (*channelName)(CFDictionaryRef);
    CFStringRef (*groupName)(CFDictionaryRef);
    CFStringRef (*subgroupName)(CFDictionaryRef);
    CFStringRef (*unitLabel)(CFDictionaryRef);
    int64_t (*simple)(CFDictionaryRef,int);
    int (*stateCount)(CFDictionaryRef);
    CFStringRef (*stateName)(CFDictionaryRef,int);
    int64_t (*residency)(CFDictionaryRef,int);
};
static bool smcCall(VCCollector *c, SMCData *in, SMCData *out) { size_t n=sizeof(*out); return c->smc && IOConnectCallStructMethod(c->smc,2,in,sizeof(*in),out,&n)==KERN_SUCCESS && out->result==0; }
static bool keyInfo(VCCollector *c,uint32_t key,SMCKeyInfo *info) { SMCData in={0},out={0}; in.key=key; in.command=9; if(!smcCall(c,&in,&out))return false; *info=out.info; return info->size>0 && info->size<=32; }
static bool keyRead(VCCollector *c,uint32_t key,SMCKeyInfo info,double *value) {
    SMCData in={0},out={0}; in.key=key; in.info=info; in.command=5;
    if(!smcCall(c,&in,&out))return false;
    uint8_t *b=out.bytes; uint32_t t=info.type; double v;
    if(t==fourcc("flt ") && info.size==4) { float f; memcpy(&f,b,4); v=f; }
    else if(t==fourcc("sp78") && info.size==2) v=(int16_t)((b[0]<<8)|b[1])/256.0;
    else if(t==fourcc("fpe2") && info.size==2) v=((b[0]<<8)|b[1])/4.0;
    else if(t==fourcc("ui8 ")) v=b[0];
    else if(t==fourcc("ui16")) v=(b[0]<<8)|b[1];
    else if(t==fourcc("ui32")) v=((uint32_t)b[0]<<24)|((uint32_t)b[1]<<16)|(b[2]<<8)|b[3];
    else if(t==fourcc("si16")) v=(int16_t)((b[0]<<8)|b[1]);
    else if((t>>16)==0x7370 && info.size==2) { int bits=(t&255)>='a'?(t&255)-'a'+10:(t&255)-'0'; v=(int16_t)((b[0]<<8)|b[1])/(double)(1u<<bits); }
    else if((t>>16)==0x6670 && info.size==2) { int bits=(t&255)>='a'?(t&255)-'a'+10:(t&255)-'0'; v=((b[0]<<8)|b[1])/(double)(1u<<bits); }
    else return false;
    if(!isfinite(v))return false;
    *value=v; return true;
}
static void setupSMC(VCCollector *c) {
    io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
    if(!s)return;
    c->smcStatus=IOServiceOpen(s,mach_task_self(),0,&c->smc); IOObjectRelease(s);
    if(!c->smc)return;
    SMCKeyInfo info; double count=0;
    if(!keyInfo(c,fourcc("#KEY"),&info) || !keyRead(c,fourcc("#KEY"),info,&count))return;
    size_t capacity=(size_t)count; if(capacity>32768) return;
    c->keys=calloc(capacity,sizeof(CachedKey));
    for(uint32_t i=0;i<capacity;i++) {
        SMCData in={0},out={0}; in.command=8; in.data32=i;
        if(!smcCall(c,&in,&out))continue;
        uint32_t key=out.key; char prefix=key>>24;
        if(prefix!='T' && prefix!='F' && key!=fourcc("PSTR") && key!=fourcc("PHPC") && key!=fourcc("PDTR") && key!=fourcc("PDBR"))continue;
        if(keyInfo(c,key,&info)) c->keys[c->keyCount++]=(CachedKey){key,info};
    }
}
#define LOAD(field,handle,symbol) *(void **)(&c->field)=dlsym(handle,symbol)
VCCollector *VCCreate(void) {
    VCCollector *c=calloc(1,sizeof(*c)); c->smcStatus=kIOReturnNotFound; setupSMC(c);
    c->iokit=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_LAZY);
    if(c->iokit) {
        LOAD(hidCreate,c->iokit,"IOHIDEventSystemClientCreate"); LOAD(hidMatch,c->iokit,"IOHIDEventSystemClientSetMatching");
        LOAD(hidServices,c->iokit,"IOHIDEventSystemClientCopyServices"); LOAD(hidProperty,c->iokit,"IOHIDServiceClientCopyProperty");
        LOAD(hidEvent,c->iokit,"IOHIDServiceClientCopyEvent"); LOAD(eventFloat,c->iokit,"IOHIDEventGetFloatValue");
        if(c->hidCreate && c->hidMatch && c->hidServices && c->hidProperty && c->hidEvent && c->eventFloat) {
            c->hid=c->hidCreate(NULL);
            if(c->hid) { CFMutableDictionaryRef m=dict(); integer(m,CFSTR("PrimaryUsagePage"),0xff00); integer(m,CFSTR("PrimaryUsage"),5); c->hidMatch(c->hid,m); CFRelease(m); c->services=c->hidServices(c->hid); }
        }
    }
    c->reportLib=dlopen("/usr/lib/libIOReport.dylib",RTLD_LAZY);
    if(c->reportLib) {
        LOAD(copyChannels,c->reportLib,"IOReportCopyChannelsInGroup"); LOAD(merge,c->reportLib,"IOReportMergeChannels");
        LOAD(subscribe,c->reportLib,"IOReportCreateSubscription"); LOAD(sample,c->reportLib,"IOReportCreateSamples");
        LOAD(delta,c->reportLib,"IOReportCreateSamplesDelta"); LOAD(iterate,c->reportLib,"IOReportIterate");
        LOAD(channelName,c->reportLib,"IOReportChannelGetChannelName"); LOAD(groupName,c->reportLib,"IOReportChannelGetGroup");
        LOAD(subgroupName,c->reportLib,"IOReportChannelGetSubGroup"); LOAD(unitLabel,c->reportLib,"IOReportChannelGetUnitLabel");
        LOAD(simple,c->reportLib,"IOReportSimpleGetIntegerValue"); LOAD(stateCount,c->reportLib,"IOReportStateGetCount");
        LOAD(stateName,c->reportLib,"IOReportStateGetNameForIndex"); LOAD(residency,c->reportLib,"IOReportStateGetResidency");
        if(c->copyChannels && c->merge && c->subscribe && c->sample && c->delta && c->iterate && c->channelName && c->groupName && c->unitLabel && c->simple && c->stateCount && c->stateName && c->residency) {
            CFStringRef groups[]={CFSTR("Energy Model"),CFSTR("CPU Stats"),CFSTR("GPU Stats")};
            CFMutableDictionaryRef all=NULL;
            for(int i=0;i<3;i++) { CFDictionaryRef d=c->copyChannels(groups[i],NULL,0,0,0); if(!d)continue; if(!all)all=CFDictionaryCreateMutableCopy(NULL,0,d); else c->merge(all,d,NULL); CFRelease(d); }
            if(all) {
                CFTypeRef channels=CFDictionaryGetValue(all,CFSTR("IOReportChannels")); CFMutableArrayRef selected=array();
                if(channels && CFGetTypeID(channels)==CFArrayGetTypeID())for(CFIndex i=0;i<CFArrayGetCount(channels);i++) {
                    CFDictionaryRef item=CFArrayGetValueAtIndex(channels,i); CFStringRef group=c->groupName(item),sub=c->subgroupName?c->subgroupName(item):NULL;
                    bool energy=group && CFStringCompare(group,CFSTR("Energy Model"),0)==0;
                    bool perf=sub && CFStringFind(sub,CFSTR("Performance States"),kCFCompareCaseInsensitive).location!=kCFNotFound;
                    if(energy || perf)CFArrayAppendValue(selected,item);
                }
                CFDictionarySetValue(all,CFSTR("IOReportChannels"),selected);
                if(CFArrayGetCount(selected)>0)c->subscription=c->subscribe(NULL,all,&c->channels,0,NULL);
                CFRelease(selected); CFRelease(all);
            }
        }
    }
    return c;
}
void VCDestroy(VCCollector *c) {
    if(!c)return;
    if(c->smc)IOServiceClose(c->smc); free(c->keys);
    if(c->services)CFRelease(c->services); if(c->hid)CFRelease(c->hid);
    if(c->previous)CFRelease(c->previous); if(c->channels)CFRelease(c->channels); if(c->subscription)CFRelease(c->subscription);
    if(c->iokit)dlclose(c->iokit); if(c->reportLib)dlclose(c->reportLib); free(c);
}
// 每秒都要的 key：CPU/GPU 核心温度、SSD、电池、风扇、功耗；其余传感器只在 full 时读
static bool fastKey(uint32_t key) {
    char a=key>>24,b=key>>16;
    if(a=='F')return true;
    if(a=='P')return true;
    return a=='T' && (b=='p' || b=='g' || b=='N' || b=='B');
}
CFDictionaryRef VCCopySensors(VCCollector *c, bool full) {
    CFMutableDictionaryRef result=dict(),temps=dict(),smc=dict(),diagnostics=dict();
    integer(diagnostics,CFSTR("SMC 打开状态"),c->smcStatus);
    integer(diagnostics,CFSTR("SMC 已发现 key 数"),c->keyCount);
    integer(diagnostics,CFSTR("HID 温度服务数"),c->services?CFArrayGetCount(c->services):0);
    integer(diagnostics,CFSTR("IOReport 已订阅"),c->subscription!=NULL);
    CFDictionarySetValue(result,CFSTR("diagnostics"),diagnostics); CFRelease(diagnostics);
    if(full && c->services)for(CFIndex i=0;i<CFArrayGetCount(c->services);i++) {
        CFTypeRef service=CFArrayGetValueAtIndex(c->services,i);
        CFTypeRef name=c->hidProperty(service,CFSTR("Product"));
        CFTypeRef event=c->hidEvent(service,15,0,0);
        if(name && CFGetTypeID(name)==CFStringGetTypeID() && event) { double value=c->eventFloat(event,15<<16); if(value>0 && value<=150)number(temps,name,value); }
        if(name)CFRelease(name); if(event)CFRelease(event);
    }
    for(size_t i=0;i<c->keyCount;i++) {
        CachedKey k=c->keys[i]; double v;
        if(!full && !fastKey(k.key))continue;
        if(!keyRead(c,k.key,k.info,&v))continue;
        char key[5]={(char)(k.key>>24),(char)(k.key>>16),(char)(k.key>>8),(char)k.key,0};
        CFStringRef name=CFStringCreateWithCString(NULL,key,kCFStringEncodingASCII); if(!name)continue;
        number(smc,name,v); CFRelease(name);
    }
    CFDictionarySetValue(result,CFSTR("hid"),temps); CFDictionarySetValue(result,CFSTR("smc"),smc); CFRelease(temps); CFRelease(smc); return result;
}
CFArrayRef VCCopyReport(VCCollector *c) {
    CFMutableArrayRef results=array(); if(!c->subscription || !c->channels)return results;
    CFDictionaryRef now=c->sample(c->subscription,c->channels,NULL); if(!now)return results;
    if(c->previous) {
        CFDictionaryRef d=c->delta(c->previous,now,NULL);
        if(d) {
            c->iterate(d,^int(CFDictionaryRef ch) {
                CFMutableDictionaryRef item=dict();
                CFStringRef name=c->channelName(ch),group=c->groupName(ch),unit=c->unitLabel(ch);
                CFStringRef subgroup=c->subgroupName ? c->subgroupName(ch) : NULL;
                if(subgroup)CFDictionarySetValue(item,CFSTR("subgroup"),subgroup);
                if(name)CFDictionarySetValue(item,CFSTR("name"),name); if(group)CFDictionarySetValue(item,CFSTR("group"),group); if(unit)CFDictionarySetValue(item,CFSTR("unit"),unit);
                if(group && CFStringCompare(group,CFSTR("Energy Model"),0)==0)integer(item,CFSTR("value"),c->simple(ch,0));
                else {
                    bool performance=subgroup && CFStringFind(subgroup,CFSTR("Performance States"),kCFCompareCaseInsensitive).location!=kCFNotFound;
                    int n=performance ? c->stateCount(ch) : 0; CFMutableArrayRef states=array();
                    if(n>0 && n<256)for(int i=0;i<n;i++) { CFMutableDictionaryRef s=dict(); CFStringRef label=c->stateName(ch,i); if(label)CFDictionarySetValue(s,CFSTR("name"),label); integer(s,CFSTR("ticks"),c->residency(ch,i)); CFArrayAppendValue(states,s); CFRelease(s); }
                    CFDictionarySetValue(item,CFSTR("states"),states); CFRelease(states);
                }
                CFArrayAppendValue(results,item); CFRelease(item); return 0;
            }); CFRelease(d);
        }
        CFRelease(c->previous);
    }
    c->previous=now; return results;
}

CFArrayRef VCCopyProcesses(void) {
    CFMutableArrayRef results=array();
    int capacity=proc_listallpids(NULL,0)+256; if(capacity<256)capacity=4096;
    pid_t *pids=calloc((size_t)capacity,sizeof(pid_t)); int count=proc_listallpids(pids,capacity*(int)sizeof(pid_t)); if(count>capacity)count=capacity;
    // 即使 taskinfo 被拒绝，也用 KERN_PROC_ALL 保留进程名称与用户。
    struct kinfo_proc *fallback=NULL; size_t length=0; int mib[]={CTL_KERN,KERN_PROC,KERN_PROC_ALL,0};
    if(sysctl(mib,4,NULL,&length,NULL,0)==0) { fallback=malloc(length); if(sysctl(mib,4,fallback,&length,NULL,0)!=0) { free(fallback); fallback=NULL; } }
    if(count<=0 && fallback) { free(pids); count=(int)(length/sizeof(*fallback)); capacity=count; pids=calloc((size_t)count,sizeof(pid_t)); for(int i=0;i<count;i++)pids[i]=fallback[i].kp_proc.p_pid; }
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    for(int i=0;i<count && i<capacity;i++) {
        pid_t pid=pids[i]; if(pid<0)continue;
        CFMutableDictionaryRef d=dict(); integer(d,CFSTR("pid"),pid);
        struct proc_bsdinfo b={0}; bool got=proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b))==(int)sizeof(b);
        char name[1024]={0},path[PROC_PIDPATHINFO_MAXSIZE]={0}; proc_name(pid,name,sizeof(name)); proc_pidpath(pid,path,sizeof(path));
        uid_t uid=0; bool hasUID=false;
        if(got) { integer(d,CFSTR("ppid"),b.pbi_ppid); uid=b.pbi_uid; hasUID=true; number(d,CFSTR("start"),(double)b.pbi_start_tvsec+(double)b.pbi_start_tvusec/1e6); if(!name[0])strlcpy(name,b.pbi_name[0]?b.pbi_name:b.pbi_comm,sizeof(name)); }
        if(!got && fallback)for(size_t j=0;j<length/sizeof(*fallback);j++)if(fallback[j].kp_proc.p_pid==pid) { struct kinfo_proc *k=&fallback[j]; uid=k->kp_eproc.e_ucred.cr_uid; hasUID=true; integer(d,CFSTR("ppid"),k->kp_eproc.e_ppid); if(!name[0])strlcpy(name,k->kp_proc.p_comm,sizeof(name)); break; }
        if(!name[0]) {
            int oneMIB[]={CTL_KERN,KERN_PROC,KERN_PROC_PID,pid}; struct kinfo_proc one={0}; size_t oneSize=sizeof(one);
            if(sysctl(oneMIB,4,&one,&oneSize,NULL,0)==0 && oneSize==sizeof(one)) { strlcpy(name,one.kp_proc.p_comm,sizeof(name)); uid=one.kp_eproc.e_ucred.cr_uid; hasUID=true; integer(d,CFSTR("ppid"),one.kp_eproc.e_ppid); }
        }
        if(!name[0])snprintf(name,sizeof(name),pid==0?"kernel_task":"PID %d",pid);
        string(d,CFSTR("name"),name); if(path[0])string(d,CFSTR("path"),path);
        if(hasUID) { struct passwd pw,*found=NULL; char buf[16384]; if(getpwuid_r(uid,&pw,buf,sizeof(buf),&found)==0 && found)string(d,CFSTR("user"),pw.pw_name); else { char value[32]; snprintf(value,sizeof(value),"%u",uid); string(d,CFSTR("user"),value); } }
        struct proc_taskinfo t={0};
        if(proc_pidinfo(pid,PROC_PIDTASKINFO,0,&t,sizeof(t))==(int)sizeof(t)) { integer(d,CFSTR("resident"),t.pti_resident_size); integer(d,CFSTR("threads"),t.pti_threadnum); number(d,CFSTR("cpuNS"),((double)t.pti_total_user+(double)t.pti_total_system)*tb.numer/tb.denom); }
        struct rusage_info_v6 r={0};
        int ok=proc_pid_rusage(pid,RUSAGE_INFO_V6,(rusage_info_t *)&r);
        if(ok!=0)ok=proc_pid_rusage(pid,RUSAGE_INFO_V4,(rusage_info_t *)&r);
        if(ok==0) {
            integer(d,CFSTR("footprint"),r.ri_phys_footprint); integer(d,CFSTR("resident"),r.ri_resident_size);
            integer(d,CFSTR("read"),r.ri_diskio_bytesread); integer(d,CFSTR("write"),r.ri_diskio_byteswritten);
            // rusage 与 taskinfo 的 CPU 时间均为 mach ticks，统一换算为纳秒。
            number(d,CFSTR("cpuNS"),((double)r.ri_user_time+(double)r.ri_system_time)*tb.numer/tb.denom);
            integer(d,CFSTR("energy"),r.ri_billed_energy); integer(d,CFSTR("identity"),r.ri_proc_start_abstime);
        }
        CFArrayAppendValue(results,d); CFRelease(d);
    }
    free(fallback); free(pids); return results;
}
CFArrayRef VCCopyNetworkCounters(void) {
    CFMutableArrayRef results=array(); int mib[]={CTL_NET,PF_ROUTE,0,0,NET_RT_IFLIST2,0}; size_t length=0;
    if(sysctl(mib,6,NULL,&length,NULL,0)!=0 || !length)return results;
    char *buffer=malloc(length); if(sysctl(mib,6,buffer,&length,NULL,0)!=0) { free(buffer); return results; }
    for(char *p=buffer;p+sizeof(struct if_msghdr)<=buffer+length;) {
        struct if_msghdr *h=(void *)p; if(!h->ifm_msglen || p+h->ifm_msglen>buffer+length)break;
        if(h->ifm_type==RTM_IFINFO2 && h->ifm_msglen>=sizeof(struct if_msghdr2)) {
            struct if_msghdr2 *m=(void *)p; char name[IF_NAMESIZE];
            if(if_indextoname(m->ifm_index,name) && strcmp(name,"lo0") && ((m->ifm_flags&IFF_UP)||m->ifm_data.ifi_ibytes||m->ifm_data.ifi_obytes)) {
                CFMutableDictionaryRef d=dict(); string(d,CFSTR("name"),name); integer(d,CFSTR("rx"),m->ifm_data.ifi_ibytes); integer(d,CFSTR("tx"),m->ifm_data.ifi_obytes); CFArrayAppendValue(results,d); CFRelease(d);
            }
        }
        p+=h->ifm_msglen;
    }
    free(buffer); return results;
}
CFDictionaryRef VCCopySystemCounts(void) {
    CFMutableDictionaryRef d=dict(); size_t n=0;
    processor_set_name_t set=MACH_PORT_NULL;
    if(processor_set_default(mach_host_self(),&set)==KERN_SUCCESS) {
        processor_set_load_info_data_t load={0}; mach_msg_type_number_t count=PROCESSOR_SET_LOAD_INFO_COUNT;
        if(processor_set_statistics(set,PROCESSOR_SET_LOAD_INFO,(processor_set_info_t)&load,&count)==KERN_SUCCESS) { integer(d,CFSTR("processes"),load.task_count); integer(d,CFSTR("threads"),load.thread_count); }
        mach_port_deallocate(mach_task_self(),set);
    }
    int processCount=proc_listallpids(NULL,0); if(processCount>0)integer(d,CFSTR("processes"),processCount);
    n=0; int pmib[]={CTL_KERN,KERN_PROC,KERN_PROC_ALL,0}; if(sysctl(pmib,4,NULL,&n,NULL,0)==0)integer(d,CFSTR("processes"),n/sizeof(struct kinfo_proc));
    return d;
}
CFArrayRef VCCopyARMFeatures(void) {
    CFMutableArrayRef result=array(); int mib[CTL_MAXNAME]; size_t miblen=CTL_MAXNAME;
    if(sysctlnametomib("hw.optional.arm",mib,&miblen)!=0)return result;
    int next[CTL_MAXNAME]; memcpy(next,mib,miblen*sizeof(int)); size_t nextlen=miblen;
    for(int i=0;i<512;i++) {
        int query[CTL_MAXNAME+2]={0,2}; memcpy(query+2,next,nextlen*sizeof(int)); size_t size=sizeof(next);
        if(sysctl(query,(u_int)nextlen+2,next,&size,NULL,0)!=0)break; nextlen=size/sizeof(int);
        if(nextlen<miblen || memcmp(next,mib,miblen*sizeof(int)))break;
        int nameMIB[CTL_MAXNAME+2]={0,1}; memcpy(nameMIB+2,next,size); char name[512]; size_t namesize=sizeof(name);
        if(sysctl(nameMIB,(u_int)nextlen+2,name,&namesize,NULL,0)==0) { int value=0; size_t vs=sizeof(value); if(sysctl(next,(u_int)nextlen,&value,&vs,NULL,0)==0) { CFMutableDictionaryRef d=dict(); string(d,CFSTR("name"),name); integer(d,CFSTR("value"),value); CFArrayAppendValue(result,d); CFRelease(d); } }
    }
    // 沙盒可能禁止 NEXT 枚举，但仍允许按名读取；补查 SDK 中的公开特性名。
    if(CFArrayGetCount(result)==0) {
        const char *features[]={"FEAT_FlagM","FEAT_FlagM2","FEAT_FHM","FEAT_DotProd","FEAT_SHA3","FEAT_RDM","FEAT_LSE","FEAT_SHA256","FEAT_SHA512","FEAT_SHA1","FEAT_AES","FEAT_PMULL","FEAT_SPECRES","FEAT_SB","FEAT_FRINTTS","FEAT_LRCPC","FEAT_LRCPC2","FEAT_FCMA","FEAT_JSCVT","FEAT_PAuth","FEAT_PAuth2","FEAT_FPAC","FEAT_DPB","FEAT_DPB2","FEAT_BF16","FEAT_I8MM","FEAT_WFxT","FEAT_RPRES","FEAT_ECV","FEAT_AFP","FEAT_LSE2","FEAT_CSV2","FEAT_CSV3","FEAT_DIT","FEAT_FP16","FEAT_SSBS","FEAT_BTI","FEAT_SME","FEAT_SME2","FEAT_SME_F64F64","FEAT_SME_I16I64","FEAT_SME2p1","FEAT_SME_F16F16","FEAT_SME_B16B16","FEAT_SME_F8F16","FEAT_SME_F8F32","AdvSIMD","AdvSIMD_HPFPCvt","FEAT_CRC32","SME_F32F32","SME_BI32I32","SME_B16F32","SME_F16F32","SME_I8I32","SME_I16I32","FEAT_PACIMP","FEAT_MTE","FEAT_MTE2","FEAT_MTE3","FEAT_MTE4","FEAT_HBC","FEAT_EBF16","FEAT_SPECRES2","FEAT_CSSC","FEAT_FPACCOMBINE","FEAT_MTE_ASYNC","FEAT_MTE_CANONICAL_TAGS","FEAT_MTE_STORE_ONLY","FEAT_MTE_NO_ADDRESS_TAGS","FP_SyncExceptions","FEAT_SVE_B16B16"};
        for(size_t i=0;i<sizeof(features)/sizeof(features[0]);i++) {
            char name[256]; snprintf(name,sizeof(name),"hw.optional.arm.%s",features[i]); int value=0; size_t size=sizeof(value);
            if(sysctlbyname(name,&value,&size,NULL,0)==0) { CFMutableDictionaryRef d=dict(); string(d,CFSTR("name"),name); integer(d,CFSTR("value"),value); CFArrayAppendValue(result,d); CFRelease(d); }
        }
    }
    return result;
}
