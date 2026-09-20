"""Planning calculations only; not synthesis or hardware measurements."""
import json
from pathlib import Path

frame_pixels = 640 * 480
frame_bytes = frame_pixels * 4
memory_bytes = 8 * 1024 * 1024
fft_cycles = (512 // 2) * 9 * 64 + 4096 + 4096 + 8192
a_9k = {'historical_baseline': 20, 'link_fifos': 4, 'packet_buffers': 2,
        'fonts_and_osd': 6, 'pcm_and_waveform': 4, 'metadata': 2}
a_32k = {'two_2048x32_video_fifos': 4, 'one_2048x32_result_fifo': 2}
b_9k = {'infrastructure_allowance_not_measured': 20, 'link_fifos': 4,
        'packet_buffers': 2, 'fonts_and_osd': 6, 'fft_and_window_coefficients': 3,
        'pcm_buffers': 4, 'metadata': 2, 'preview_line_cache': 2}
b_32k = {'two_2048x32_source_rows': 4, 'two_512x36_fft_banks': 6,
         'one_2048x32_result_fifo': 2}
a_lut = {'baseline_rounded': 4000, 'fat32_bmp': 1500, 'memory_scheduler': 1500,
         'pixel_processing_osd': 1800, 'second_video_tx': 2500,
         'link': 1500, 'scene_control': 700}
b_lut = {'infrastructure': 3000, 'scaler': 1800, 'fft_audio': 2500,
         'link': 1500, 'ui': 1500, 'task_control': 1000}
data = {
 'status': 'Analytical model and design allocations; not measured utilization',
 'per_board': {'lut':19600,'ff':19600,'multipliers_18x18':29,'eram9k':64,
               'eram32k':16,'eram_bytes':64*9216//8+16*32768//8,
               'sdram_bytes':memory_bytes,'pll':4},
 'A': {'lut_allocations':a_lut,'lut_total_allocated':sum(a_lut.values()),
       'dsp_allocated':12,'eram9k_allocations':a_9k,'eram9k_total':sum(a_9k.values()),
       'eram32k_allocations':a_32k,'eram32k_total':sum(a_32k.values()),
       'sdram_main_bytes':3*frame_bytes,'sdram_main_fraction':3*frame_bytes/memory_bytes,
       'pll_allocated':3},
 'B': {'lut_allocations':b_lut,'lut_total_allocated':sum(b_lut.values()),
       'dsp_allocated':14,'eram9k_allocations':b_9k,'eram9k_total':sum(b_9k.values()),
       'eram32k_allocations':b_32k,'eram32k_total':sum(b_32k.values()),
       'sdram_main_bytes':2*frame_bytes+2*160*120*2,
       'sdram_main_fraction':(2*frame_bytes+2*160*120*2)/memory_bytes,
       'pll_allocated':2,'pll_with_interface_contingency':3},
 'compute': {'fft_butterflies':256*9,'fft_cycle_budget':fft_cycles,
             'fft_compute_ms_at_50MHz':fft_cycles/50e6*1000,
             'fft_window_ms':512/48000*1000,
             'fft_fraction_of_window':fft_cycles/50e6/(512/48000),
             'scaler_cycles_at_24_cycles_per_output_pixel':frame_pixels*24,
             'scaler_compute_ms_at_50MHz':frame_pixels*24/50e6*1000},
 'bandwidth': {'A_two_frame_reads_MBps_at_60Hz':2*frame_bytes*60/1e6,
               'A_result_writes_MBps_at_wire_peak':10*4/3,
               'A_aggregate_MBps':2*frame_bytes*60/1e6+10*4/3,
               'A_aggregate_with_30pct_margin_MBps':(2*frame_bytes*60/1e6+10*4/3)*1.3,
               'A_effective_sdram_gate_MBps':220,
               'wire_payload_ratio_512_plus32':512/(512+32),
               'PCM_MBps':48000*2/1e6,
               'FFT_result_MBps_with_64B_packet_at100Hz':64*100/1e6,
               'min_read_fifo_time_us_at512pixels_and25p175MHz':512/25.175e6*1e6,
               'tf_min_640x480_seconds_at25MHz':frame_pixels*3/(25e6/8),
               'tf_min_1280x960_seconds_at25MHz':1280*960*3/(25e6/8)}
}
out = Path(__file__).resolve().with_name('resource_budget.json')
out.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(data, ensure_ascii=True, indent=2))

