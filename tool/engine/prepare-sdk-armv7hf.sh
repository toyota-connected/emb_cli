#! /bin/bash

pushd $1

SYSROOT=$2

mkdir -p engine-sdk/{bin,include,lib,data,clang_x64/bin,clang_x64/lib64}

# 
# Include
# 
cp *.h engine-sdk/include/

# 
# /data 
# 
cp icudtl.dat engine-sdk/data/

#
# cpp_client_wrapper_glfw
#
if [ -e cpp_client_wrapper_glfw ]; then
    mkdir -p engine-sdk/sdk/cpp_client_wrapper_glfw/
	cp -r cpp_client_wrapper_glfw/* engine-sdk/sdk/cpp_client_wrapper_glfw/
fi

# 
# flutter_linux
# 
if [ -e flutter_linux ]; then
    mkdir -p engine-sdk/include/flutter_linux
    cp -r flutter_linux/* engine-sdk/include/flutter_linux/
fi

#
# flutter_patched_sdk
#
if [ -e flutter_patched_sdk ]; then
    mkdir -p engine-sdk/sdk/flutter_patched_sdk
    cp -r flutter_patched_sdk/* engine-sdk/sdk/flutter_patched_sdk/
fi

#
# shader_lib
#
if [ -e shader_lib ]; then
    mkdir -p engine-sdk/sdk/flutter_patched_sdk
	cp -r shader_lib engine-sdk/
fi

#
# zip archives
#
if [ -e zip_archives ]; then
    mkdir -p engine-sdk/sdk/zip_archives
	cp -r zip_archives/* engine-sdk/sdk/zip_archives/
fi

export cwd=$(pwd)

# 
# host - x64
# 
cd clang_x64/exe.unstripped
for file in *; do
    cp "../$file" $cwd/engine-sdk/clang_x64/bin/

    # Copy each library with its parent directories to the target directory
    for library in $(ldd "$file" | cut -d '>' -f 2 | awk '{print $1}')
    do
        [ -f "${library}" ] && cp --verbose --parents "${library}" "$cwd/engine-sdk/clang_x64/"
    done
done
cd $cwd

# 
# /lib
# 
cd so.unstripped
for file in *; do
    cp "../$file" $cwd/engine-sdk/lib/
done
cd $cwd

popd
