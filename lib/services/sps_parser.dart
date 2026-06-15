import 'dart:typed_data';

/// H.264 SPS (Sequence Parameter Set) parser.
/// Extracts video resolution from SPS NAL units.
class SpsParser {
  /// Find all NAL units in H.264 bitstream data.
  /// Yields (nalType, nalData) for each NAL unit found.
  static Iterable<({int type, Uint8List data})> findNalUnits(Uint8List data) sync* {
    var i = 0;
    while (i < data.length - 3) {
      // Find start code: 0x000001 or 0x00000001
      int startCodeLen;
      if (data[i] == 0 && data[i + 1] == 0) {
        if (i + 3 < data.length && data[i + 2] == 0 && data[i + 3] == 1) {
          startCodeLen = 4;
        } else if (data[i + 2] == 1) {
          startCodeLen = 3;
        } else {
          i++;
          continue;
        }
      } else {
        i++;
        continue;
      }

      final nalStart = i + startCodeLen;
      if (nalStart >= data.length) break;
      final nalType = data[nalStart] & 0x1F;

      // Find next start code to determine NAL end
      var j = nalStart + 1;
      while (j < data.length - 3) {
        if (data[j] == 0 && data[j + 1] == 0) {
          if ((j + 3 < data.length && data[j + 2] == 0 && data[j + 3] == 1) ||
              data[j + 2] == 1) {
            break;
          }
        }
        j++;
      }
      if (j >= data.length - 3) j = data.length;

      yield (type: nalType, data: data.sublist(nalStart, j));
      i = j;
    }
  }

  /// Check if a frame contains an SPS NAL unit (type 7).
  static bool containsSps(Uint8List frameData) {
    for (final nal in findNalUnits(frameData)) {
      if (nal.type == 7) return true;
    }
    return false;
  }

  /// Parse SPS NAL unit and extract resolution.
  /// Returns (width, height) or null if parsing fails.
  static ({int width, int height})? parseSps(Uint8List spsData) {
    try {
      final br = _BitReader(spsData);

      // Determine header size: start code (3 or 4 bytes) + NAL type byte (1 byte)
      if (spsData.length > 4 &&
          spsData[0] == 0 && spsData[1] == 0 &&
          spsData[2] == 0 && spsData[3] == 1) {
        br.pos = 40; // 4-byte start code + 1 NAL byte
      } else if (spsData.length > 3 &&
          spsData[0] == 0 && spsData[1] == 0 && spsData[2] == 1) {
        br.pos = 32; // 3-byte start code + 1 NAL byte
      } else {
        // No start code — data begins with NAL type byte
        br.pos = 8; // skip NAL type byte
      }

      // profile_idc (8 bits)
      var profileIdc = 0;
      for (var i = 0; i < 8; i++) {
        profileIdc = (profileIdc << 1) | br.readBit();
      }

      // constraint_set flags + reserved (8 bits)
      for (var i = 0; i < 8; i++) {
        br.readBit();
      }

      // level_idc (8 bits)
      for (var i = 0; i < 8; i++) {
        br.readBit();
      }

      br.readUe(); // seq_parameter_set_id

      // High profile has extra fields
      if (profileIdc == 100 || profileIdc == 110 || profileIdc == 122 ||
          profileIdc == 244 || profileIdc == 44 || profileIdc == 83 ||
          profileIdc == 86 || profileIdc == 118 || profileIdc == 128) {
        final chromaFormatIdc = br.readUe();
        if (chromaFormatIdc == 3) br.readBit(); // separate_colour_plane_flag
        br.readUe(); // bit_depth_luma_minus8
        br.readUe(); // bit_depth_chroma_minus8
        br.readBit(); // qpprime_y_zero_transform_bypass_flag
        final seqScalingMatrixPresent = br.readBit() != 0;
        if (seqScalingMatrixPresent) {
          final cnt = chromaFormatIdc != 3 ? 8 : 12;
          for (var j = 0; j < cnt; j++) {
            if (br.readBit() != 0) {
              // seq_scaling_list_present
              final size = j < 6 ? 16 : 64;
              var lastScale = 8;
              var nextScale = 8;
              for (var k = 0; k < size; k++) {
                if (nextScale != 0) {
                  final delta = br.readUe();
                  nextScale = (lastScale + delta + 256) % 256;
                }
                lastScale = nextScale != 0 ? nextScale : lastScale;
              }
            }
          }
        }
      }

      br.readUe(); // log2_max_frame_num_minus4
      final picOrderCntType = br.readUe();
      if (picOrderCntType == 0) {
        br.readUe(); // log2_max_pic_order_cnt_lsb_minus4
      } else if (picOrderCntType == 1) {
        br.readBit(); // delta_pic_order_always_zero_flag
        br.readUe(); // offset_for_non_ref_pic
        br.readUe(); // offset_for_top_to_bottom_field
        final numRefFrames = br.readUe();
        for (var j = 0; j < numRefFrames; j++) {
          br.readUe();
        }
      }

      br.readUe(); // max_num_ref_frames
      br.readBit(); // gaps_in_frame_num_value_allowed_flag

      final picWidthInMbs = br.readUe() + 1;
      final picHeightInMapUnits = br.readUe() + 1;
      final frameMbsOnly = br.readBit() != 0;

      var width = picWidthInMbs * 16;
      var height = picHeightInMapUnits * (frameMbsOnly ? 16 : 32);

      // frame_mbs_only_flag (already read above)
      if (!frameMbsOnly) {
        br.readBit(); // mb_adaptive_frame_field_flag
      }
      br.readBit(); // direct_8x8_inference_flag
      final frameCroppingFlag = br.readBit() != 0;
      if (frameCroppingFlag) {
        final cropLeft = br.readUe();
        final cropRight = br.readUe();
        final cropTop = br.readUe();
        final cropBottom = br.readUe();
        // Adjust for YUV 4:2:0 cropping
        width -= (cropLeft + cropRight) * 2;
        height -= (cropTop + cropBottom) * 2;
      }

      return (width: width, height: height);
    } catch (e) {
      return null;
    }
  }
}

/// Bit-level reader for Exp-Golomb coded values in H.264 bitstream.
class _BitReader {
  final Uint8List data;
  int pos = 0; // bit position

  _BitReader(this.data);

  int readBit() {
    if (pos >= data.length * 8) return 0;
    final byteIdx = pos ~/ 8;
    final bitIdx = pos % 8;
    pos++;
    return (data[byteIdx] >> (7 - bitIdx)) & 1;
  }

  /// Read unsigned Exp-Golomb coded value.
  int readUe() {
    var zeros = 0;
    while (readBit() == 0 && zeros < 32) {
      zeros++;
    }
    // The terminating 1-bit was consumed by the loop.
    // Read 'zeros' info bits, then combine: value = (1 << zeros) + info - 1
    var info = 0;
    for (var i = 0; i < zeros; i++) {
      info = (info << 1) | readBit();
    }
    return ((1 << zeros) - 1) + info;
  }

  /// Read signed Exp-Golomb coded value.
  int readSe() {
    final val = readUe();
    if (val % 2 == 0) return -(val ~/ 2);
    return (val + 1) ~/ 2;
  }
}
