module Kernel

using CUDA
using GemmKernels
using GemmKernels.Tiling
using GPUifyLoops: @unroll
using StaticArrays

function matmul_impl(a, b, c, d,
                     transf_gl2sh_a, transf_gl2sh_b, transf_gl2sh_c, transf_sh2gl_d,
                     transf_sh2rf_a, transf_sh2rf_b, transf_sh2rf_c, transf_rf2sh_d,
                     epilogue,
                     conf::Type{GemmKernels.Config{MATMUL_SHAPE, BLOCK_SHAPE, WARPS_PER_BLOCK, MEM_A_WARP, MEM_A_THREAD, MEM_B_WARP, MEM_B_THREAD, MEM_CD_WARP, MEM_CD_THREAD, COMPUTE_WARP, COMPUTE_OP_SHAPE, GLOBAL_A_LAYOUT, GLOBAL_B_LAYOUT, GLOBAL_C_LAYOUT, GLOBAL_D_LAYOUT, SHARED_A_LAYOUT, SHARED_B_LAYOUT, SHARED_C_LAYOUT, SHARED_D_LAYOUT, OPERATOR, IS_A_COL_MAJOR, IS_B_COL_MAJOR}}) where {MATMUL_SHAPE, BLOCK_SHAPE, WARPS_PER_BLOCK, MEM_A_WARP, MEM_A_THREAD, MEM_B_WARP, MEM_B_THREAD, MEM_CD_WARP, MEM_CD_THREAD, COMPUTE_WARP, COMPUTE_OP_SHAPE, GLOBAL_A_LAYOUT, GLOBAL_B_LAYOUT, GLOBAL_C_LAYOUT, GLOBAL_D_LAYOUT, SHARED_A_LAYOUT, SHARED_B_LAYOUT, SHARED_C_LAYOUT, SHARED_D_LAYOUT, OPERATOR, IS_A_COL_MAJOR, IS_B_COL_MAJOR}
    # Calculate the number of fragments needed to fully cover a warp tile
    NUM_FRAGMENTS_M = COMPUTE_WARP.M ÷ COMPUTE_OP_SHAPE.M
    NUM_FRAGMENTS_N = COMPUTE_WARP.N ÷ COMPUTE_OP_SHAPE.N

    # Constants
    block_i = (blockIdx().x - 1) * BLOCK_SHAPE.M
    block_j = (blockIdx().y - 1) * BLOCK_SHAPE.N

    warpId = (threadIdx().x - 1) ÷ 32 + 1
    laneId = (threadIdx().x - 1) % 32 + 1

    gemm_sz = Tile(MATMUL_SHAPE)
    block_tile = Tile(BLOCK_SHAPE)

    # (1) Cooperatively load a BLOCK_SHAPE.M x BLOCK_SHAPE.N tile of C from global to shared memory within one threadblock
    shmem_c = @cuDynamicSharedMem(Layout.eltype(SHARED_C_LAYOUT), Layout.physical_size(SHARED_C_LAYOUT, block_tile.MN.size))

    @unroll for warp_tile = parallellise(block_tile.MN, Tile(MEM_CD_WARP), warpId, WARPS_PER_BLOCK)
        @unroll for thread_tile = parallellise(warp_tile, Tile(MEM_CD_THREAD), laneId, 32)
            x = Layout.load(GLOBAL_C_LAYOUT, c, translate_base(thread_tile, (M = block_i, N = block_j)))
            x = transf_gl2sh_c(x, thread_tile)
            Layout.store!(SHARED_C_LAYOUT, shmem_c, x, thread_tile)
        end
    end

    sync_threads()

    # (2) Load a COMPUTE_WARP.M x COMPUTE_WARP.N tile of C from shared memory into registers
    warp_tile = subdivide(block_tile.MN, Tile(COMPUTE_WARP).MN, warpId, WARPS_PER_BLOCK)

    c_frags = MArray{Tuple{NUM_FRAGMENTS_M, NUM_FRAGMENTS_N}, Operator.fragtype_accum(OPERATOR, SHARED_C_LAYOUT)}(undef)

    @unroll for i = 1 : NUM_FRAGMENTS_M
        @unroll for j = 1 : NUM_FRAGMENTS_N
            tile = translate_offset(warp_tile, (M = (i-1)*COMPUTE_OP_SHAPE.M, N = (j-1)*COMPUTE_OP_SHAPE.N))
            @inbounds c_frags[i, j] = transf_sh2rf_c(Operator.load_c(OPERATOR, SHARED_C_LAYOUT, shmem_c, tile), tile)
        end
    end

    sync_threads()

    # (3) Compute a BLOCK_SHAPE.M x BLOCK_SHAPE.N x BLOCK_SHAPE.K matrix product within one threadblock
    shmem_a = @cuDynamicSharedMem(Layout.eltype(SHARED_A_LAYOUT), Layout.physical_size(SHARED_A_LAYOUT, block_tile.MK.size))
    shmem_b = @cuDynamicSharedMem(Layout.eltype(SHARED_B_LAYOUT), Layout.physical_size(SHARED_B_LAYOUT, block_tile.KN.size),
                                    length(shmem_a) * sizeof(Layout.eltype(SHARED_A_LAYOUT)))

    @unroll for block_k = 0 : block_tile.size.K : gemm_sz.size.K - 1
        if Layout.threadblock_condition(GLOBAL_A_LAYOUT, GLOBAL_B_LAYOUT, block_i, block_j, block_k, block_tile)
            # (3.1) Cooperatively load a BLOCK_SHAPE.M x BLOCK_SHAPE.K tile of A from global to shared memory within one threadblock
            @unroll for warp_tile = parallellise(block_tile.MK, Tile(MEM_A_WARP), warpId, WARPS_PER_BLOCK, IS_A_COL_MAJOR)
                @unroll for thread_tile = parallellise(warp_tile, Tile(MEM_A_THREAD), laneId, 32, IS_A_COL_MAJOR)
                    x = Layout.load(GLOBAL_A_LAYOUT, a, translate_base(thread_tile, (M = block_i, K = block_k)))
                    x = transf_gl2sh_a(x, thread_tile)
                    Layout.store!(SHARED_A_LAYOUT, shmem_a, x, thread_tile)
                end
            end

            # (3.2) Cooperatively load a BLOCK_SHAPE.K x BLOCK_SHAPE.N tile of B from global to shared memory within one threadblock
            @unroll for warp_tile = parallellise(block_tile.KN, Tile(MEM_B_WARP), warpId, WARPS_PER_BLOCK, IS_B_COL_MAJOR)
                @unroll for thread_tile = parallellise(warp_tile, Tile(MEM_B_THREAD), laneId, 32, IS_B_COL_MAJOR)
                    x = Layout.load(GLOBAL_B_LAYOUT, b, translate_base(thread_tile, (K = block_k, N = block_j)))
                    x = transf_gl2sh_b(x, thread_tile)
                    Layout.store!(SHARED_B_LAYOUT, shmem_b, x, thread_tile)
                end
            end

            sync_threads()

            # (3.3) Calculate a COMPUTE_WARP.M x COMPUTE_WARP.N tile of D, using a COMPUTE_WARP.M x COMPUTE_WARP.N x COMPUTE_WARP.K operation
            @unroll for warp_tile = parallellise(block_tile, Tile(COMPUTE_WARP), warpId, WARPS_PER_BLOCK)
                # (3.3.1) Load a COMPUTE_WARP.M x COMPUTE_WARP.K tile of A from shared memory into registers
                a_frags = MArray{Tuple{NUM_FRAGMENTS_M}, Operator.fragtype_a(OPERATOR, SHARED_A_LAYOUT)}(undef)

                @unroll for i = 1 : NUM_FRAGMENTS_M
                    a_tile = translate_offset(warp_tile.MK, (M = (i-1)*COMPUTE_OP_SHAPE.M, K = 0))
                    @inbounds a_frags[i] = transf_sh2rf_a(Operator.load_a(OPERATOR, SHARED_A_LAYOUT, shmem_a, a_tile), a_tile)
                end

                # (3.3.2) Load a COMPUTE_WARP.K x COMPUTE_WARP.N tile of B from shared memory into registers
                b_frags = MArray{Tuple{NUM_FRAGMENTS_N}, Operator.fragtype_b(OPERATOR, SHARED_B_LAYOUT)}(undef)

                @unroll for j = 1 : NUM_FRAGMENTS_N
                    b_tile = translate_offset(warp_tile.KN, (K = 0, N = (j-1)*COMPUTE_OP_SHAPE.N))
                    @inbounds b_frags[j] = transf_sh2rf_b(Operator.load_b(OPERATOR, SHARED_B_LAYOUT, shmem_b, b_tile), b_tile)
                end

                # (3.3.3) Compute a COMPUTE_WARP.M x COMPUTE_WARP.N x COMPUTE_WARP.K matrix product within one warp
                @unroll for i = 1 : NUM_FRAGMENTS_M
                    @unroll for j = 1 : NUM_FRAGMENTS_N
                        @inbounds c_frags[i, j] = Operator.mma(OPERATOR, a_frags[i], b_frags[j], c_frags[i, j])
                    end
                end
            end
        end

        sync_threads()
    end

    # (4) Store the COMPUTE_WARP.M x COMPUTE_WARP.N tile of D from registers to shared memory
    shmem_d = @cuDynamicSharedMem(Layout.eltype(SHARED_D_LAYOUT), Layout.physical_size(SHARED_D_LAYOUT, block_tile.MN.size))

    warp_tile = subdivide(block_tile.MN, Tile(COMPUTE_WARP).MN, warpId, WARPS_PER_BLOCK)

    @unroll for i = 1 : NUM_FRAGMENTS_M
        @unroll for j = 1 : NUM_FRAGMENTS_N
            tile = translate_offset(warp_tile, (M = (i-1)*COMPUTE_OP_SHAPE.M, N = (j-1)*COMPUTE_OP_SHAPE.N))
            Operator.store_d(OPERATOR, SHARED_D_LAYOUT, shmem_d, transf_rf2sh_d(c_frags[i, j], tile), tile)
        end
    end

    sync_threads()

    # (5) Run the epilogue
    epilogue(d, shmem_d, transf_sh2gl_d, conf)

    return
end

end
