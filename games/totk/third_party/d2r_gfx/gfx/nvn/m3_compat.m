// Metal 4 → Metal 3 兼容层实现（DM_NVN_M3=1）
// Implementation of the Metal 4 -> Metal 3 compatibility layer.
#import "m3_compat.h"
#if DM_NVN_M3

#import <os/lock.h>
#import <string.h>
#import <stdio.h>
#import <stdlib.h>

// ---------------------------------------------------------------------------
// GPU 地址 → MTLBuffer 反查表
// ---------------------------------------------------------------------------
// Kept sorted by GPU address and searched by halving, so a binding costs O(log n) whatever the number of buffers; it grows
// as needed (a fixed table of M3_BUFS entries dropped later buffers silently, and their bindings then bound nothing).
// Distinct MTLBuffers never share GPU addresses, so the entry at or below an address is the only one that can hold it.
typedef struct { uint64_t gpu, len; __unsafe_unretained id<MTLBuffer> buf; } m3_buf_ent;
static m3_buf_ent *g_m3_bufs;
static int g_m3_nbufs, g_m3_cap;
static os_unfair_lock g_m3_lk = OS_UNFAIR_LOCK_INIT;

// The first entry whose address is above gpu (callers hold the lock).
static int m3_upper(uint64_t gpu) {
    int lo = 0, hi = g_m3_nbufs;
    while (lo < hi) { int mid = (lo + hi) / 2; if (g_m3_bufs[mid].gpu <= gpu) lo = mid + 1; else hi = mid; }
    return lo;
}

void m3_buf_add(id<MTLBuffer> b) {
    if (!b) return;
    uint64_t gpu = b.gpuAddress, len = b.length;
    os_unfair_lock_lock(&g_m3_lk);
    if (g_m3_nbufs == g_m3_cap) {
        int cap = g_m3_cap ? g_m3_cap * 2 : M3_BUFS;
        m3_buf_ent *grown = realloc(g_m3_bufs, (size_t)cap * sizeof *grown);
        if (!grown) { os_unfair_lock_unlock(&g_m3_lk); fprintf(stderr, "[dm] [m3] buffer table: out of memory at %d buffers\n", g_m3_nbufs); return; }
        g_m3_bufs = grown; g_m3_cap = cap;
    }
    int i = m3_upper(gpu);
    memmove(&g_m3_bufs[i + 1], &g_m3_bufs[i], (size_t)(g_m3_nbufs - i) * sizeof *g_m3_bufs);
    g_m3_bufs[i] = (m3_buf_ent){gpu, len, b};
    g_m3_nbufs++;
    os_unfair_lock_unlock(&g_m3_lk);
}

void m3_buf_del(id<MTLBuffer> b) {
    if (!b) return;
    uint64_t gpu = b.gpuAddress;
    os_unfair_lock_lock(&g_m3_lk);
    int i = m3_upper(gpu) - 1;
    if (i < 0 || g_m3_bufs[i].buf != b)   // not where its address puts it: look everywhere (never expected)
        for (i = g_m3_nbufs - 1; i >= 0 && g_m3_bufs[i].buf != b; i--) {}
    if (i >= 0) { memmove(&g_m3_bufs[i], &g_m3_bufs[i + 1], (size_t)(g_m3_nbufs - i - 1) * sizeof *g_m3_bufs); g_m3_nbufs--; }
    os_unfair_lock_unlock(&g_m3_lk);
}

id<MTLBuffer> m3_buf(uint64_t gpu, NSUInteger *off) {
    id<MTLBuffer> r = nil;
    *off = 0;
    if (!gpu) return nil;
    os_unfair_lock_lock(&g_m3_lk);
    int i = m3_upper(gpu) - 1;
    if (i >= 0 && gpu - g_m3_bufs[i].gpu < g_m3_bufs[i].len) { r = g_m3_bufs[i].buf; *off = (NSUInteger)(gpu - g_m3_bufs[i].gpu); }
    os_unfair_lock_unlock(&g_m3_lk);
    return r;
}

// ---------------------------------------------------------------------------
// 当前编码器（供时间戳采样用；Metal 3 的计数采样挂在编码器上而不是命令缓冲上）
// Current encoder (for counter sampling: Metal 3 samples on an encoder, not on a command buffer).
// ---------------------------------------------------------------------------
static __unsafe_unretained id g_m3_cur_enc;

void m3_set_cur_enc(id enc) { g_m3_cur_enc = enc; }

// ---------------------------------------------------------------------------
// 参数表
// ---------------------------------------------------------------------------
@implementation M3ArgTableDescriptor
@end

static int g_m3_red_bound;   // 未登记地址只报一次红，避免刷屏 | report an unregistered address once

@implementation M3ArgTable

- (void)setAddress:(uint64_t)gpu atIndex:(NSUInteger)i {
    NSUInteger off = 0;
    id<MTLBuffer> b = m3_buf(gpu, &off);
    if (gpu && !b) {
        if (!g_m3_red_bound++) fprintf(stderr, "[dm] [m3] 【红】绑定：显卡地址 %#llx 不在任何登记过的缓冲里（槽 %lu）\n",
                                       (unsigned long long)gpu, (unsigned long)i);
        return;
    }
    switch (_stage) {
        case M3_STAGE_VERTEX:   [(id<MTLRenderCommandEncoder>)_enc setVertexBuffer:b offset:off atIndex:i]; break;
        case M3_STAGE_FRAGMENT: [(id<MTLRenderCommandEncoder>)_enc setFragmentBuffer:b offset:off atIndex:i]; break;
        default:                [(id<MTLComputeCommandEncoder>)_enc setBuffer:b offset:off atIndex:i]; break;
    }
}

- (void)setTexture:(id<MTLTexture>)tex atIndex:(NSUInteger)i {
    switch (_stage) {
        case M3_STAGE_VERTEX:   [(id<MTLRenderCommandEncoder>)_enc setVertexTexture:tex atIndex:i]; break;
        case M3_STAGE_FRAGMENT: [(id<MTLRenderCommandEncoder>)_enc setFragmentTexture:tex atIndex:i]; break;
        default:                [(id<MTLComputeCommandEncoder>)_enc setTexture:tex atIndex:i]; break;
    }
}

- (void)setSamplerState:(id<MTLSamplerState>)smp atIndex:(NSUInteger)i {
    switch (_stage) {
        case M3_STAGE_VERTEX:   [(id<MTLRenderCommandEncoder>)_enc setVertexSamplerState:smp atIndex:i]; break;
        case M3_STAGE_FRAGMENT: [(id<MTLRenderCommandEncoder>)_enc setFragmentSamplerState:smp atIndex:i]; break;
        default:                [(id<MTLComputeCommandEncoder>)_enc setSamplerState:smp atIndex:i]; break;
    }
}

@end

void m3_attach(M3ArgTable *t, id enc, int stage) {
    t.enc = enc;
    t.stage = stage;
}

// ---------------------------------------------------------------------------
// GPU 时间戳
// ---------------------------------------------------------------------------
@implementation M3CounterHeapDescriptor
@end

@implementation M3CounterHeap {
    id<MTLCounterSampleBuffer> _sb;
}

- (instancetype)initWithDevice:(id<MTLDevice>)dev count:(NSUInteger)count {
    if ((self = [super init])) {
        id<MTLCounterSet> set = nil;
        for (id<MTLCounterSet> cs in [dev counterSets])
            if ([[cs name] isEqualToString:MTLCommonCounterSetTimestamp]) { set = cs; break; }
        if (!set) { fprintf(stderr, "[dm] [m3] 【红】设备没有 timestamp 计数器集\n"); return self; }
        MTLCounterSampleBufferDescriptor *d = [MTLCounterSampleBufferDescriptor new];
        d.counterSet = set;
        d.sampleCount = count;
        d.storageMode = MTLStorageModeShared;
        NSError *e = nil;
        _sb = [dev newCounterSampleBufferWithDescriptor:d error:&e];
        if (!_sb) fprintf(stderr, "[dm] [m3] 【红】建立计数器采样缓冲失败：%s\n", e.localizedDescription.UTF8String);
    }
    return self;
}

- (id<MTLCounterSampleBuffer>)sampleBuffer { return _sb; }

- (NSData *)resolveCounterRange:(NSRange)r { return [_sb resolveCounterRange:r]; }

@end

// 在「当前编码器」上采一个时间戳；Metal 3 没有命令缓冲级别的写法
// Sample one timestamp on the current encoder; Metal 3 has no command-buffer-level form.
void m3_timestamp(M3CounterHeap *h, NSUInteger i) {
    if (!h || !g_m3_cur_enc) return;
    id<MTLCounterSampleBuffer> sb = [h sampleBuffer];
    if (!sb) return;
    id e = g_m3_cur_enc;
    if ([e conformsToProtocol:@protocol(MTLRenderCommandEncoder)])
        [(id<MTLRenderCommandEncoder>)e sampleCountersInBuffer:sb atSampleIndex:i withBarrier:NO];
    else if ([e conformsToProtocol:@protocol(MTLComputeCommandEncoder)])
        [(id<MTLComputeCommandEncoder>)e sampleCountersInBuffer:sb atSampleIndex:i withBarrier:NO];
    else if ([e conformsToProtocol:@protocol(MTLBlitCommandEncoder)])
        [(id<MTLBlitCommandEncoder>)e sampleCountersInBuffer:sb atSampleIndex:i withBarrier:NO];
}

// ---------------------------------------------------------------------------
// 提交回调
// ---------------------------------------------------------------------------
@implementation M3CommitFeedback
+ (instancetype)withCommandBuffer:(id<MTLCommandBuffer>)cb {
    M3CommitFeedback *f = [M3CommitFeedback new];
    f->_GPUStartTime = cb.GPUStartTime;
    f->_GPUEndTime = cb.GPUEndTime;
    f->_error = cb.error;
    return f;
}
@end

void m3_commit(id<MTLCommandBuffer> cb, M3CommitOptions *o) {
    if (!cb) return;
    if (o.handlers.count) {
        NSArray *hs = [o.handlers copy];
        [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
            M3CommitFeedback *fb = [M3CommitFeedback withCommandBuffer:c];
            for (M3CommitFeedbackHandler h in hs) h(fb);
        }];
    }
    [cb commit];
    /* 判定用：TOTK_M3_SYNC_PRESENT=1 时每次提交后等 GPU 完成，排除 drawable 重叠使用时序 */
    /* Diagnostic: with TOTK_M3_SYNC_PRESENT=1 wait for the GPU after every commit, to rule out drawable overlap. */
    static int syncp = -1;
    if (syncp < 0) syncp = getenv("TOTK_M3_SYNC_PRESENT") != NULL;
    if (syncp) [cb waitUntilCompleted];
}

@implementation M3CommitOptions

- (void)addFeedbackHandler:(M3CommitFeedbackHandler)block {
    if (!_handlers) _handlers = [NSMutableArray array];
    if (block) [_handlers addObject:[block copy]];
}

@end

// ---------------------------------------------------------------------------
// 命令分配器 / 队列描述符（Metal 3 无对应概念，只承接属性赋值）
// ---------------------------------------------------------------------------
@implementation M3CommandAllocatorDescriptor
@end
@implementation M3CommandAllocator
@end
@implementation M3CommandQueueDescriptor
@end

// ---------------------------------------------------------------------------
// 着色器编译
// ---------------------------------------------------------------------------
@implementation M3CompilerDescriptor
@end

@implementation M3Compiler {
    id<MTLDevice> _dev;
}

- (instancetype)initWithDevice:(id<MTLDevice>)dev {
    if ((self = [super init])) _dev = dev;
    return self;
}

- (id<MTLLibrary>)newLibraryWithSource:(NSString *)src options:(MTLCompileOptions *)opts error:(NSError **)err {
    return [_dev newLibraryWithSource:src options:opts error:err];
}

@end

void m3_draw_indexed(id enc, MTLPrimitiveType p, NSUInteger n, MTLIndexType t,
                     uint64_t gpu, NSUInteger len, NSUInteger inst, NSInteger baseV, NSUInteger baseI) {
    (void)len;
    if (!n) return;
    NSUInteger off = 0;
    id<MTLBuffer> b = m3_buf(gpu, &off);
    if (!b) return;
    [(id<MTLRenderCommandEncoder>)enc drawIndexedPrimitives:p indexCount:n indexType:t
                                                indexBuffer:b indexBufferOffset:off
                                              instanceCount:inst baseVertex:baseV baseInstance:baseI];
}

#endif /* DM_NVN_M3 */
