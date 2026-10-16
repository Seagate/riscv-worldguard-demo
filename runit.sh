#!/usr/bin/sh
#
mkdir -p ~/wg-demo/traces

docker run -it --rm -p 2323:2323 \
	-v ~/wg-demo/traces:/out \
	wg-demo
