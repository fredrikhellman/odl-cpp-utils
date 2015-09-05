#include <algorithm>
#include <memory>

// includes CUDA Runtime
#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <cublas_v2.h>

// thrust
#include <LCRUtils/cuda/disableThrustWarnings.h>
#include <thrust/iterator/reverse_iterator.h>
#include <thrust/iterator/constant_iterator.h>
#include <thrust/device_vector.h>
#include <thrust/transform.h>
#include <thrust/inner_product.h>
#include <thrust/adjacent_difference.h>
#include <LCRUtils/cuda/enableThrustWarnings.h>

// Thrust bug...
#define DEBUG 1
#include <boost/python.hpp>
#include <boost/python/slice.hpp>
#include <iostream>
#define _DEBUG 1

#include <numpy/numpyconfig.h>
#define NPY_NO_DEPRECATED_API NPY_1_7_API_VERSION
#include <numpy/arrayobject.h>

// ODL
#include <ODLpp/DeviceVectorImpl.h>
#include <ODLpp/TypeMacro.h>
#include <ODLpp/CudaVectorImpl.h>

// Utils
#include <LCRUtils/cuda/thrustUtils.h>

struct sliceHelper {
    sliceHelper(const slice& index, ptrdiff_t n) : arraySize(n) {
        extract<ptrdiff_t> stepIn(index.step());
        if (stepIn.check())
            step = stepIn();
        else
            step = 1;

        if (step == 0) throw std::invalid_argument("step = 0 is not valid");

        extract<ptrdiff_t> startIn(index.start());
        if (startIn.check()) {
            if (step > 0) {
                start = startIn();
                if (start < 0) start += n;
            } else {
                start = startIn() + 1;
                if (start <= 0) start += n;
            }
        } else if (step > 0)
            start = 0;
        else
            start = n;

        extract<ptrdiff_t> stopIn(index.stop());
        if (stopIn.check()) {
            if (step > 0) {
                stop = stopIn();
                if (stop < 0) stop += n;
            } else {
                stop = stopIn() + 1;
                if (stop <= 0) stop += n;
            }
        } else if (step > 0)
            stop = n;
        else
            stop = 0;

        if (start == stop)
            numel = 0;
        else if (step > 0)
            numel = std::max<ptrdiff_t>(0, 1 + (stop - start - 1) / step);
        else
            numel =
                std::max<ptrdiff_t>(0, 1 + (start - stop - 1) / std::abs(step));

        if (start < 0 || stop > arraySize)
            throw std::out_of_range("Slice index out of range");
    }

    friend std::ostream& operator<<(std::ostream& ss, const sliceHelper& sh) {
        return ss << "Slice, start: " << sh.start << ", stop: " << sh.stop
                  << ", step: " << sh.step << ", numel: " << sh.numel;
    }
    ptrdiff_t start, stop, step, numel, arraySize;
};

template <typename I1, typename I2>
void stridedGetImpl(I1 fromBegin, I1 fromEnd, I2 toBegin, int step) {
    if (step == 1) {
        thrust::copy(fromBegin, fromEnd, toBegin);
    } else {
        auto iter = make_strided_range(fromBegin, fromEnd, step);
        thrust::copy(iter.begin(), iter.end(), toBegin);
    }
}

template <typename I1, typename I2>
void stridedSetImpl(I1 fromBegin, I1 fromEnd, I2 toBegin, I2 toEnd, int step) {
    if (step == 1) {
        thrust::copy(fromBegin, fromEnd, toBegin);
    } else {
        auto iter = make_strided_range(toBegin, toEnd, step);
        thrust::copy(fromBegin, fromEnd, iter.begin());
    }
}
template <typename T>
void getSliceImpl(const DeviceVector<T>& v1, int start, int stop, int step,
                  T* target) {
    if (step > 0) {
        stridedGetImpl(v1.begin() + start, v1.begin() + stop, target, step);
    } else {
        auto reversedBegin = thrust::make_reverse_iterator(v1.begin() + start);
        auto reversedEnd = thrust::make_reverse_iterator(v1.begin() + stop);

        stridedGetImpl(reversedBegin, reversedEnd, target, -step);
    }
}
template <typename T>
void setSliceImpl(DeviceVector<T>& v1, int start, int stop, int step,
                  const T* source, int num) {
    if (step > 0) {
        stridedSetImpl(source, source + num, v1.begin() + start,
                       v1.begin() + stop, step);
    } else {
        auto reversedBegin = thrust::make_reverse_iterator(v1.begin() + start);
        auto reversedEnd = thrust::make_reverse_iterator(v1.begin() + stop);

        stridedSetImpl(source, source + num, reversedBegin, reversedEnd, -step);
    }
}
template <typename T>
CudaVectorImpl<T>::CudaVectorImpl(size_t size)
    : _size(size), _impl(std::make_shared<ThrustDeviceVector<T>>(size)) {}

template <typename T>
CudaVectorImpl<T>::CudaVectorImpl(size_t size, T value)
    : _size(size),
      _impl(std::make_shared<ThrustDeviceVector<T>>(size, value)) {}

template <typename T>
CudaVectorImpl<T>::CudaVectorImpl(size_t size, DeviceVectorPtr<T> impl)
    : _size(size), _impl(impl) {}

template <typename T>
CudaVectorImpl<T> CudaVectorImpl<T>::fromPointer(uintptr_t ptr, size_t size) {
    return {size, std::make_shared<WrapperDeviceVector<T>>(
                      reinterpret_cast<T*>(ptr), size)};
}

template <typename T>
void CudaVectorImpl<T>::validateIndex(ptrdiff_t index) const {
    if (index < 0 || index >= _size)
        throw std::out_of_range("index out of range");
}

template <typename T>
T CudaVectorImpl<T>::getItem(ptrdiff_t index) const {
    if (index < 0) index += _size;  // Handle negative indexes like python
    validateIndex(index);
    return _impl->operator[](index);
}

template <typename T>
void CudaVectorImpl<T>::setItem(ptrdiff_t index, T value) {
    if (index < 0) index += _size;  // Handle negative indexes like python
    validateIndex(index);
    _impl->operator[](index) = value;
}

template <typename T>
boost::python::numeric::array CudaVectorImpl<T>::getSlice(
    const boost::python::slice index) const {
    sliceHelper sh(index, _size);
    _import_array();
    if (sh.numel > 0) {
        numeric::array arr = makeArray<T>(sh.numel);
        getSliceImpl(*_impl, sh.start, sh.stop, sh.step, getDataPtr<T>(arr));
        return arr;
    } else {
        return makeArray<T>(0);
    }
}

template <typename T>
void CudaVectorImpl<T>::setSlice(const boost::python::slice index,
                                 const boost::python::numeric::array& arr) {
    sliceHelper sh(index, _size);

    if (sh.numel != len(arr))
        throw std::out_of_range("Size of array does not match slice");

    if (sh.numel > 0) {
        setSliceImpl(*_impl, sh.start, sh.stop, sh.step, getDataPtr<T>(arr),
                     sh.numel);
    }
}

template <typename T>
void linCombImpl(DeviceVector<T>& z, T a, const DeviceVector<T>& x, T b,
                 const DeviceVector<T>& y) {
    namespace ph = thrust::placeholders;

#if 1  // Efficient
    if (a == T(0)) {
        if (b == T(0)) {  // z = 0
            thrust::fill(z.begin(), z.end(), T(0));
        } else if (b == T(1)) {  // z = y
            thrust::copy(y.begin(), y.end(), z.begin());
        } else if (b == -T(1)) {  // y = -y
            thrust::transform(y.begin(), y.end(), z.begin(), -ph::_1);
        } else {  // y = b*y
            thrust::transform(y.begin(), y.end(), z.begin(), b * ph::_1);
        }
    } else if (a == T(1)) {
        if (b == T(0)) {  // z = x
            thrust::copy(x.begin(), x.end(), z.begin());
        } else if (b == T(1)) {  // z = x+y
            thrust::transform(x.begin(), x.end(), y.begin(), z.begin(),
                              ph::_1 + ph::_2);
        } else if (b == -T(1)) {  // z = x-y
            thrust::transform(x.begin(), x.end(), y.begin(), z.begin(),
                              ph::_1 - ph::_2);
        } else {  // z = x + b*y
            thrust::transform(x.begin(), x.end(), y.begin(), z.begin(),
                              ph::_1 + b * ph::_2);
        }
    } else if (a == -T(1)) {
        if (b == T(0)) {  // z = -x
            thrust::transform(x.begin(), x.end(), z.begin(), -ph::_1);
        } else if (b == T(1)) {  // z = -x+y
            thrust::transform(x.begin(), x.end(), y.begin(), z.begin(),
                              -ph::_1 + ph::_2);
        } else if (b == -T(1)) {  // z = -x-y
            thrust::transform(x.begin(), x.end(), y.begin(), z.begin(),
                              -ph::_1 - ph::_2);
        } else {  // z = -x + b*y
            thrust::transform(x.begin(), x.end(), y.begin(), z.begin(),
                              -ph::_1 + b * ph::_2);
        }
    } else {
        if (b == T(0)) {  // z = a*x
            thrust::transform(x.begin(), x.end(), z.begin(), a * ph::_1);
        } else if (b == T(1)) {  // z = a*x+y
            thrust::transform(x.begin(), x.end(), y.begin(), z.begin(),
                              a * ph::_1 + ph::_2);
        } else if (b == -T(1)) {  // z = a*x-y
            thrust::transform(x.begin(), x.end(), y.begin(), z.begin(),
                              a * ph::_1 - ph::_2);
        } else {  // z = a*x + b*y
            thrust::transform(x.begin(), x.end(), y.begin(), z.begin(),
                              a * ph::_1 + b * ph::_2);
        }
    }
#else  // Basic
    thrust::transform(x.begin(), x.end(), y.begin(), z.begin(),
                      a * ph::_1 + b * ph::_2);
#endif
}

template <typename T>
void CudaVectorImpl<T>::linComb(T a, const CudaVectorImpl<T>& x, T b,
                                const CudaVectorImpl<T>& y) {
    linCombImpl(*this->_impl, a, *x._impl, b, *y._impl);
}

template <typename T>
struct DistanceFunctor {
    __host__ __device__ double operator()(const thrust::tuple<T, T>& f) const {
        return (thrust::get<0>(f) - thrust::get<1>(f)) *
               (thrust::get<0>(f) - thrust::get<1>(f));
    }
};

template <typename T>
double CudaVectorImpl<T>::dist(const CudaVectorImpl<T>& other) const {
    auto first = thrust::make_zip_iterator(
        thrust::make_tuple(this->_impl->begin(), other._impl->begin()));
    auto last = first + this->size();
    return sqrt(thrust::transform_reduce(first, last, DistanceFunctor<T>{}, 0.0,
                                         thrust::plus<double>{}));
}

template <typename T>
double CudaVectorImpl<T>::norm() const {
    namespace ph = thrust::placeholders;
    return sqrt(thrust::transform_reduce(this->_impl->begin(),
                                         this->_impl->end(), ph::_1 * ph::_1,
                                         0.0, thrust::plus<double>{}));
}

template <typename T>
double CudaVectorImpl<T>::inner(const CudaVectorImpl<T>& other) const {
    return thrust::inner_product(this->_impl->begin(), this->_impl->end(),
                                 other._impl->begin(), 0.0);
}

template <typename T>
void CudaVectorImpl<T>::multiply(const CudaVectorImpl<T>& x,
                                 const CudaVectorImpl<T>& y) {
    namespace ph = thrust::placeholders;
    thrust::transform(x._impl->begin(), x._impl->end(), y._impl->begin(),
                      this->_impl->begin(), ph::_1 * ph::_2);
}

template <typename T>
CudaVectorImpl<T> CudaVectorImpl<T>::copy() const {
    return CudaVectorImpl<T>{_size,
                             std::make_shared<ThrustDeviceVector<T>>(*_impl)};
}

template <typename T>
bool CudaVectorImpl<T>::allEqual(const CudaVectorImpl<T>& other) const {
    return thrust::equal(this->_impl->begin(), this->_impl->end(),
                         other._impl->begin());
}

template <typename T>
void CudaVectorImpl<T>::printData(std::ostream_iterator<T>& out,
                                  int numel) const {
    thrust::copy(this->_impl->begin(), this->_impl->begin() + numel, out);
}

template <typename T>
CudaVectorImpl<T>::operator DeviceVector<T>&() {
    return *this->_impl;
}

template <typename T>
CudaVectorImpl<T>::operator const DeviceVector<T>&() const {
    return *this->_impl;
}

template <typename T>
uintptr_t CudaVectorImpl<T>::dataPtr() const {
    return reinterpret_cast<uintptr_t>(_impl->data());
}

// Instantiate the methods for each type
template struct CudaVectorImpl<char>;
template struct CudaVectorImpl<signed char>;
template struct CudaVectorImpl<signed short>;
template struct CudaVectorImpl<signed int>;
template struct CudaVectorImpl<signed long>;
template struct CudaVectorImpl<signed long long>;
template struct CudaVectorImpl<unsigned char>;
template struct CudaVectorImpl<unsigned short>;
template struct CudaVectorImpl<unsigned int>;
template struct CudaVectorImpl<unsigned long>;
template struct CudaVectorImpl<unsigned long long>;
template struct CudaVectorImpl<float>;
template struct CudaVectorImpl<double>;