#pragma OPENCL EXTENSION cl_khr_fp16 : enable

#ifdef cl_intel_subgroups
#pragma OPENCL EXTENSION cl_intel_subgroups : enable
#else
#pragma OPENCL EXTENSION cl_khr_subgroups : enable
#endif

#ifdef cl_intel_required_subgroup_size
#pragma OPENCL EXTENSION cl_intel_required_subgroup_size : enable
#define INTEL_GPU 1
#define REQD_SUBGROUP_SIZE_16 __attribute__((intel_reqd_sub_group_size(16)))
#define REQD_SUBGROUP_SIZE_32 __attribute__((intel_reqd_sub_group_size(32)))
#elif defined(cl_qcom_reqd_sub_group_size)
#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
#define ADRENO_GPU 1
#define REQD_SUBGROUP_SIZE_64  __attribute__((qcom_reqd_sub_group_size("half")))
#define REQD_SUBGROUP_SIZE_128 __attribute__((qcom_reqd_sub_group_size("full")))
#endif

#define QK4_0                   32
#define QR4_0                   2
#define QK4_1                   32
#define QR4_1                   2
#define QK5_0                   32
#define QR5_0                   2
#define QK5_1                   32
#define QR5_1                   2
#define QK8_0                   32
#define QR8_0                   1
#define QK_K                    256
#define K_QUANTS_PER_ITERATION  2

typedef char int8_t;
typedef uchar uint8_t;
typedef short int16_t;
typedef ushort uint16_t;
typedef int int32_t;
typedef uint uint32_t;

//------------------------------------------------------------------------------
// block_q4_0
//------------------------------------------------------------------------------
struct block_q4_0
{
    half d;
    uint8_t qs[QK4_0 / 2];
};

//
// This variant unrolls the loops and uses vector types instead of pointers.
// It improves performance on Adreno but not so much on Intel.
//
inline float block_q_4_0_dot_y_v(
        global struct block_q4_0 * qb_curr,
        float sumy,
        float16 yl,
        int il
) {
    float d = qb_curr->d;
    float acc = 0.f;
    global ushort * qs = ((global ushort *)qb_curr + 1 + il/2);

    acc += yl.s0 * (qs[0] & 0x000F);
    acc += yl.s1 * (qs[0] & 0x0F00);
    acc += yl.s8 * (qs[0] & 0x00F0);
    acc += yl.s9 * (qs[0] & 0xF000);

    acc += yl.s2 * (qs[1] & 0x000F);
    acc += yl.s3 * (qs[1] & 0x0F00);
    acc += yl.sa * (qs[1] & 0x00F0);
    acc += yl.sb * (qs[1] & 0xF000);

    acc += yl.s4 * (qs[2] & 0x000F);
    acc += yl.s5 * (qs[2] & 0x0F00);
    acc += yl.sc * (qs[2] & 0x00F0);
    acc += yl.sd * (qs[2] & 0xF000);

    acc += yl.s6 * (qs[3] & 0x000F);
    acc += yl.s7 * (qs[3] & 0x0F00);
    acc += yl.se * (qs[3] & 0x00F0);
    acc += yl.sf * (qs[3] & 0xF000);

    return d * (sumy * -8.f + acc);
}

#undef N_DST
#undef N_SIMDGROUP
#undef N_SIMDWIDTH

#ifdef INTEL_GPU
#define N_DST 4 // each SIMD group works on 4 rows
#define N_SIMDGROUP 1 // number of SIMD groups in a thread group
#define N_SIMDWIDTH 16 // assuming SIMD group size is 16
#elif defined (ADRENO_GPU)
#define N_DST 4
#define N_SIMDGROUP 1
#define N_SIMDWIDTH 64
#endif

inline void mul_vec_q_n_f32_v(
        global void * src0,
        global float * src1,
        global float * dst,
        int ne00,
        int ne01,
        int ne02,
        int ne10,
        int ne12,
        int ne0,
        int ne1,
        int r2,
        int r3
) {
    const ulong nb = ne00/QK4_0;

    int r0 = get_group_id(0);
    int r1 = get_group_id(1);
    int im = get_group_id(2);

    // (r0 * N_SIMDGROUP + get_sub_group_id()) is essenatially the linear global
    // id of a SIMD group in the grid.
    int first_row = (r0 * N_SIMDGROUP + get_sub_group_id()) * N_DST;

    int i12 = im%ne12;
    int i13 = im/ne12;

    ulong offset0 = first_row * nb + (i12/r2)*(nb*ne01) + (i13/r3)*(nb*ne01*ne02);

    global struct block_q4_0 * x = (global struct block_q4_0 *) src0 + offset0;
    global float             * y = (global float             *) src1 + r1*ne10 + im*ne00*ne1;

    float16 yl;       // src1 vector cache
    float4 sumf = (float4)(0.f, 0.f, 0.f, 0.f);

    int ix = get_sub_group_local_id()/2;
    int il = 8*(get_sub_group_local_id()%2);

    global float * yb = y + ix * QK4_0 + il;

    // each thread in a SIMD group deals with half a block.
    for (int ib = ix; ib < nb; ib += N_SIMDWIDTH/2) {
        float sumy = 0;

        sumy += yb[0];
        sumy += yb[1];
        sumy += yb[2];
        sumy += yb[3];
        sumy += yb[4];
        sumy += yb[5];
        sumy += yb[6];
        sumy += yb[7];

        sumy += yb[16];
        sumy += yb[17];
        sumy += yb[18];
        sumy += yb[19];
        sumy += yb[20];
        sumy += yb[21];
        sumy += yb[22];
        sumy += yb[23];


        yl.s0 = yb[0];
        yl.s1 = yb[1]/256.f;

        yl.s2 = yb[2];
        yl.s3 = yb[3]/256.f;

        yl.s4 = yb[4];
        yl.s5 = yb[5]/256.f;

        yl.s6 = yb[6];
        yl.s7 = yb[7]/256.f;

        yl.s8 = yb[16]/16.f;
        yl.s9 = yb[17]/4096.f;

        yl.sa = yb[18]/16.f;
        yl.sb = yb[19]/4096.f;

        yl.sc = yb[20]/16.f;
        yl.sd = yb[21]/4096.f;

        yl.se = yb[22]/16.f;
        yl.sf = yb[23]/4096.f;

        sumf.s0 += block_q_4_0_dot_y_v(x+ib+0*nb, sumy, yl, il);
        sumf.s1 += block_q_4_0_dot_y_v(x+ib+1*nb, sumy, yl, il);
        sumf.s2 += block_q_4_0_dot_y_v(x+ib+2*nb, sumy, yl, il);
        sumf.s3 += block_q_4_0_dot_y_v(x+ib+3*nb, sumy, yl, il);

        // One thread in a SIMD group (i.e., subgroup) handles a half block,
        // hence then entire SIMD group handles SIMDWIDTH/2 blocks.
        // y points to the activation matrix (of type float). Therefore for
        // one thread, the # of blocks y should advance is SIMDWIDTH/2 (because
        // SIMDWIDTH/2 blocks are processed by a SIMD group) - in terms of
        // floats, it is QK4_0 * (SIMDWIDTH/2), where QK4_0 is the block size.
        yb += QK4_0 * (N_SIMDWIDTH/2);
    }

    // The above does not work for Adreno - it produces incorrect results for
    // row = 1, 2, 3 and only row = 0 gives the correct result.
    // If N_DST is changed, the below array must be initialized accordingly.
    // This also seems to perform better on Intel.
    float4 tot = (float4)(
        sub_group_reduce_add(sumf.s0), sub_group_reduce_add(sumf.s1),
        sub_group_reduce_add(sumf.s2), sub_group_reduce_add(sumf.s3)
    );

    if (get_sub_group_local_id() == 0) {
        if (first_row + 0 < ne01) {
            dst[r1*ne0 + im*ne0*ne1 + first_row + 0] = tot.s0;
        }
        if (first_row + 1 < ne01) {
            dst[r1*ne0 + im*ne0*ne1 + first_row + 1] = tot.s1;
        }
        if (first_row + 2 < ne01) {
            dst[r1*ne0 + im*ne0*ne1 + first_row + 2] = tot.s2;
        }
        if (first_row + 3 < ne01) {
            dst[r1*ne0 + im*ne0*ne1 + first_row + 3] = tot.s3;
        }
    }
}

#ifdef INTEL_GPU
REQD_SUBGROUP_SIZE_16
#elif defined (ADRENO_GPU)
REQD_SUBGROUP_SIZE_64
#endif
kernel void kernel_mul_mat_q4_0_f32_v(
        global void * src0,
        ulong offset0,
        global float * src1,
        ulong offset1,
        global float * dst,
        ulong offsetd,
        int ne00,
        int ne01,
        int ne02,
        int ne10,
        int ne12,
        int ne0,
        int ne1,
        int r2,
        int r3
) {
    src0 = (global void*)((global char*)src0 + offset0);
    src1 = (global float*)((global char*)src1 + offset1);
    dst = (global float*)((global char*)dst + offsetd);

    mul_vec_q_n_f32_v(src0, src1, dst, ne00, ne01, ne02, ne10, ne12, ne0, ne1, r2, r3);
}
