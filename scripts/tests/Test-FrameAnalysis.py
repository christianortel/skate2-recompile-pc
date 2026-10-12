import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("frame_analysis", Path(__file__).resolve().parents[1] / "analyze_frame_times.py")
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)


class FrameAnalysisTest(unittest.TestCase):
    def test_known_cadence_stalls_and_partial_tail(self):
        directory = Path(__file__).resolve().parents[2] / "reports" / "frame-analysis-test"
        directory.mkdir(parents=True, exist_ok=True)
        source = directory / "frames.csv"
        source.write_text("frame_time_us,pipeline_cache_misses,command_buffer_stalls,draw_calls\n"
                          "0,0,0,0\n16667,0,0,4\n33333,0,0,4\n50000,2,1,4\n100000,0,3,4\n9999,", encoding="utf-8")
        result = analysis.analyze(source)
        self.assertEqual(result["frames"], 4)
        self.assertAlmostEqual(result["effective_swap_fps"], 20)
        self.assertAlmostEqual(result["included_seconds"], .2)
        self.assertAlmostEqual(result["frame_ms"]["median"], 41.6665)
        self.assertEqual(result["frames_over_50_ms"], 1)
        self.assertEqual(result["frames_over_100_ms"], 0)
        self.assertEqual(result["pipeline_cache_misses"], 2)
        self.assertEqual(result["command_buffer_stalls"], 4)
        self.assertTrue(result["incomplete_tail_discarded"])
        selected = analysis.analyze(source, .049, .101)
        self.assertEqual(selected["frames"], 1)
        self.assertEqual(selected["frame_ms"]["maximum"], 50)
        with self.assertRaises(ValueError):
            analysis.analyze(source, 1, 2)
        with self.assertRaises(ValueError):
            analysis.analyze(source, start_utc="2026-10-12T01:40:00Z")

    def test_utc_alignment(self):
        directory = Path(__file__).resolve().parents[2] / "reports" / "frame-analysis-test"
        directory.mkdir(parents=True, exist_ok=True)
        source = directory / "anchored.csv"
        anchor = analysis.utc_microseconds("2026-10-12T01:40:00Z")
        source.write_text("timestamp_utc_us,frame_time_us\n"
                          f"{anchor},0\n{anchor + 20000},20000\n{anchor + 40000},20000\n"
                          f"{anchor + 80000},40000\n", encoding="utf-8")
        result = analysis.analyze(source, start_utc="2026-10-12T01:40:00.020Z",
                                 end_utc="2026-10-12T01:40:00.080Z")
        self.assertEqual(result["frames"], 2)
        self.assertAlmostEqual(result["effective_swap_fps"], 100 / 3)
        self.assertEqual(result["observed_utc"]["last_interval_end"], "2026-10-12T01:40:00.080000+00:00")
        with self.assertRaises(ValueError):
            analysis.utc_microseconds("2026-10-12T01:40:00")


if __name__ == "__main__":
    unittest.main()
