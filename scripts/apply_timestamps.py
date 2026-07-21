#!/usr/bin/env python3
"""
Apply frame timestamps from Firefox StreamDumper log to H.264 elementary stream.
Uses PyAV to remux with correct VFR timestamps.
"""
import sys
import re

try:
    import av
except ImportError:
    print("ERROR: PyAV not available", file=sys.stderr)
    sys.exit(1)


def extract_timestamps(log_file):
    """Extract frame timestamps from Firefox StreamDumper log."""
    timestamps = []
    pattern = re.compile(r'\[StreamDumper\] frame=\d+ time=(\d+)us')
    
    with open(log_file, 'r') as f:
        for line in f:
            m = pattern.search(line)
            if m:
                # Convert microseconds to seconds (float)
                ts_us = int(m.group(1))
                timestamps.append(ts_us / 1_000_000.0)
    
    return timestamps


def apply_timestamps(input_h264, output_mkv, timestamps):
    """Remux H.264 stream with custom frame timestamps."""
    if not timestamps:
        print("No timestamps provided", file=sys.stderr)
        return False
    
    # Open input H.264 stream
    in_container = av.open(input_h264, format='h264')
    in_stream = in_container.streams.video[0]
    
    # Create output MKV
    out_container = av.open(output_mkv, 'w', format='matroska')
    out_stream = out_container.add_stream('h264', rate=None)  # VFR
    out_stream.width = in_stream.width
    out_stream.height = in_stream.height
    out_stream.pix_fmt = in_stream.pix_fmt or 'yuv420p'
    # Use microsecond time base for precision
    out_stream.time_base = av.time_base  # 1/1000000
    
    # Copy codec parameters
    out_stream.codec_context.extradata = in_stream.codec_context.extradata
    
    # Process frames
    frame_idx = 0
    for packet in in_container.demux(in_stream):
        if frame_idx >= len(timestamps):
            break
            
        # Set custom PTS (in microseconds, matching our time_base)
        pts_us = int(timestamps[frame_idx] * 1_000_000)
        packet.pts = pts_us
        packet.dts = pts_us
        packet.stream = out_stream
        
        out_container.mux(packet)
        frame_idx += 1
    
    out_container.close()
    in_container.close()
    
    print(f"Applied {frame_idx} frame timestamps", file=sys.stderr)
    return frame_idx > 0


def main():
    if len(sys.argv) != 4:
        print("Usage: apply_timestamps.py <input.h264> <firefox.log> <output.mkv>", file=sys.stderr)
        sys.exit(1)
    
    input_h264 = sys.argv[1]
    log_file = sys.argv[2]
    output_mkv = sys.argv[3]
    
    timestamps = extract_timestamps(log_file)
    if not timestamps:
        print("No timestamps found in log", file=sys.stderr)
        sys.exit(1)
    
    print(f"Extracted {len(timestamps)} timestamps from log", file=sys.stderr)
    
    success = apply_timestamps(input_h264, output_mkv, timestamps)
    if not success:
        sys.exit(1)
    
    print("Success", file=sys.stderr)


if __name__ == '__main__':
    main()
