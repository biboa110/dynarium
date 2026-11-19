// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <new>

/* Header-only polymorphic allocator primitives for darwin/cpu.
 *
 * Xcode 26's iOS SDK exposes std::pmr headers whose runtime symbols
 * (notably std::pmr::memory_resource::~memory_resource and
 * std::pmr::new_delete_resource) reside in libc++.1.dylib starting on iOS 17.
 * Keeping these interfaces inline inside uml::cpu::pmr guarantees zero
 * dynamic-linker dependencies beyond iOS 16.0. */
namespace uml::cpu::pmr {

class memory_resource {
public:
	static constexpr std::size_t max_align = alignof(std::max_align_t);

	memory_resource() = default;
	memory_resource(const memory_resource &) = default;
	memory_resource &operator=(const memory_resource &) = default;
	virtual ~memory_resource() = default;

	[[nodiscard]] void *allocate(
		std::size_t bytes,
		std::size_t alignment = max_align)
	{
		return do_allocate(bytes, alignment);
	}

	void deallocate(
		void *ptr,
		std::size_t bytes,
		std::size_t alignment = max_align) noexcept
	{
		do_deallocate(ptr, bytes, alignment);
	}

	[[nodiscard]] bool is_equal(const memory_resource &other) const noexcept
	{
		return do_is_equal(other);
	}

protected:
	[[nodiscard]] virtual void *do_allocate(
		std::size_t bytes, std::size_t alignment) = 0;
	virtual void do_deallocate(
		void *ptr, std::size_t bytes, std::size_t alignment) = 0;
	[[nodiscard]] virtual bool do_is_equal(
		const memory_resource &other) const noexcept = 0;
};

[[nodiscard]] inline bool operator==(
	const memory_resource &lhs, const memory_resource &rhs) noexcept
{
	return &lhs == &rhs || lhs.is_equal(rhs);
}

namespace detail {

class NewDeleteResource final : public memory_resource {
protected:
	[[nodiscard]] void *do_allocate(
		std::size_t bytes, std::size_t alignment) override
	{
		if (alignment > __STDCPP_DEFAULT_NEW_ALIGNMENT__) {
			return ::operator new(
				bytes, std::align_val_t{alignment});
		}
		return ::operator new(bytes);
	}

	void do_deallocate(
		void *ptr, std::size_t bytes, std::size_t alignment) override
	{
		(void)bytes;
		if (alignment > __STDCPP_DEFAULT_NEW_ALIGNMENT__) {
			::operator delete(ptr, std::align_val_t{alignment});
			return;
		}
		::operator delete(ptr);
	}

	[[nodiscard]] bool do_is_equal(
		const memory_resource &other) const noexcept override
	{
		return this == &other;
	}
};

} // namespace detail

[[nodiscard]] inline memory_resource *new_delete_resource() noexcept
{
	[[clang::no_destroy]] static detail::NewDeleteResource instance;
	return &instance;
}

[[nodiscard]] inline memory_resource *get_default_resource() noexcept
{
	return new_delete_resource();
}

class monotonic_buffer_resource final : public memory_resource {
public:
	monotonic_buffer_resource() noexcept
		: monotonic_buffer_resource(get_default_resource())
	{}

	explicit monotonic_buffer_resource(memory_resource *upstream) noexcept
		: upstream_{upstream != nullptr ? upstream : get_default_resource()}
	{}

	explicit monotonic_buffer_resource(
		std::size_t initial_size,
		memory_resource *upstream = get_default_resource()) noexcept
		: next_buffer_size_{next_size(initial_size)},
		  upstream_{upstream != nullptr ? upstream : get_default_resource()}
	{}

	monotonic_buffer_resource(
		void *buffer,
		std::size_t buffer_size,
		memory_resource *upstream = get_default_resource()) noexcept
		: initial_buffer_{buffer},
		  initial_size_{buffer != nullptr ? buffer_size : 0U},
		  current_{buffer},
		  remaining_{buffer != nullptr ? buffer_size : 0U},
		  next_buffer_size_{next_size(buffer != nullptr ? buffer_size : 0U)},
		  upstream_{upstream != nullptr ? upstream : get_default_resource()}
	{}

	monotonic_buffer_resource(const monotonic_buffer_resource &) = delete;
	monotonic_buffer_resource &operator=(
		const monotonic_buffer_resource &) = delete;

	~monotonic_buffer_resource() override
	{
		release();
	}

	void release() noexcept
	{
		ChunkHeader *chunk = head_;
		head_ = nullptr;
		while (chunk != nullptr) {
			ChunkHeader *next = chunk->next;
			const std::size_t bytes = chunk->allocated_bytes;
			const std::size_t align = chunk->allocated_align;
			chunk->~ChunkHeader();
			upstream_->deallocate(chunk, bytes, align);
			chunk = next;
		}
		current_ = initial_buffer_;
		remaining_ = initial_size_;
		next_buffer_size_ = next_size(initial_size_);
	}

	[[nodiscard]] memory_resource *upstream_resource() const noexcept
	{
		return upstream_;
	}

protected:
	[[nodiscard]] void *do_allocate(
		std::size_t bytes, std::size_t alignment) override
	{
		const std::size_t request_bytes = std::max<std::size_t>(bytes, 1U);
		const std::size_t request_align = std::max<std::size_t>(alignment, 1U);

		if (void *aligned = std::align(
			    request_align, request_bytes, current_, remaining_);
		    aligned != nullptr) {
			current_ = static_cast<std::byte *>(aligned) + request_bytes;
			remaining_ -= request_bytes;
			return aligned;
		}

		const std::size_t chunk_align = std::max<std::size_t>(
			alignof(ChunkHeader), request_align);
		const std::size_t header_size = sizeof(ChunkHeader);
		const std::size_t align_slack =
			request_align > 1U ? request_align - 1U : 0U;
		if (request_bytes >
		    std::numeric_limits<std::size_t>::max() - header_size - align_slack) {
			throw std::bad_alloc{};
		}
		const std::size_t min_bytes = header_size + align_slack + request_bytes;
		const std::size_t chunk_bytes = std::max(next_buffer_size_, min_bytes);
		next_buffer_size_ =
			chunk_bytes <= std::numeric_limits<std::size_t>::max() / 2U
				? chunk_bytes * 2U
				: chunk_bytes;

		void *raw = upstream_->allocate(chunk_bytes, chunk_align);
		auto *header = new (raw) ChunkHeader{head_, chunk_bytes, chunk_align};
		head_ = header;

		void *cursor = static_cast<std::byte *>(raw) + header_size;
		std::size_t space = chunk_bytes - header_size;
		void *aligned = std::align(
			request_align, request_bytes, cursor, space);
		if (aligned == nullptr) {
			throw std::bad_alloc{};
		}
		current_ = static_cast<std::byte *>(aligned) + request_bytes;
		remaining_ = space - request_bytes;
		return aligned;
	}

	void do_deallocate(
		void *, std::size_t, std::size_t) override
	{
		// Monotonic buffer frees only in release() and destruction.
	}

	[[nodiscard]] bool do_is_equal(
		const memory_resource &other) const noexcept override
	{
		return this == &other;
	}

private:
	struct ChunkHeader final {
		ChunkHeader *next;
		std::size_t allocated_bytes;
		std::size_t allocated_align;
	};

	static constexpr std::size_t default_initial_size = 1024U;

	[[nodiscard]] static constexpr std::size_t next_size(
		std::size_t seed) noexcept
	{
		if (seed < default_initial_size) {
			return default_initial_size;
		}
		if (seed <= std::numeric_limits<std::size_t>::max() / 2U) {
			return seed * 2U;
		}
		return seed;
	}

	void *initial_buffer_{};
	std::size_t initial_size_{};
	void *current_{};
	std::size_t remaining_{};
	std::size_t next_buffer_size_{default_initial_size};
	ChunkHeader *head_{};
	memory_resource *upstream_;
};

} // namespace uml::cpu::pmr
