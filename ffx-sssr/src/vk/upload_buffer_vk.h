/**********************************************************************
Copyright (c) 2020 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
********************************************************************/
#pragma once

#include <vulkan/vulkan.h>

#include "memory.h"
#include "buffer_vk.h"

namespace ffx_sssr
{
    class Context;
    class ContextVK;

    /**
        The UploadBufferVK class allows to transfer some memory from the CPU to the GPU.
    */
    class UploadBufferVK
    {
        FFX_SSSR_NON_COPYABLE(UploadBufferVK);

    public:
        UploadBufferVK(ContextVK& context, std::size_t buffer_size);
        ~UploadBufferVK();

        void Initialize();

        inline std::size_t GetSize() const;
        inline VkBuffer GetResource() const;
        inline std::size_t GetOffset(void *data) const;

        template<typename TYPE>
        bool AllocateBuffer(std::size_t size, TYPE*& data);
    protected:

        bool AllocateBufferInternal(std::size_t size, void*& data);

        /**
            The Block class represents an individual synchronizable block to be upload for memory upload.
        */
        class Block
        {
        public:
            inline Block();

            inline bool CanBeReused() const;

            // The index of the currently calculated frame.
            std::uint32_t* frame_index_;
            // The frame at which this block was created.
            std::uint32_t block_index_;
            // The number of elapsed frames before re-use.
            std::uint32_t frame_count_before_reuse_;
        };

        // The pointer to the mapped data.
        void* data_;
        // The context to be used.
        ContextVK& context_;
        // The resource to the upload buffer.
        BufferVK buffer_;
        // The maximum size of the buffer in bytes.
        std::size_t buffer_size_;
        // The available blocks for memory upload.
        RingBuffer<Block> blocks_;
    };
}

#include "upload_buffer_vk.inl"
