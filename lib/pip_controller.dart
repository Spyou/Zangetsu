import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart'; // Ou o player usado no projeto

class PipController extends ChangeNotifier {
  static final PipController instance = PipController._();
    PipController._();

      bool isPipActive = false;
        VideoController? videoController;
          Offset position = const Offset(20, 100);

            void enablePip(VideoController controller) {
                videoController = controller;
                    isPipActive = true;
                        notifyListeners();
                          }

                            void disablePip() {
                                isPipActive = false;
                                    videoController = null;
                                        notifyListeners();
                                          }

                                            void updatePosition(Offset delta) {
                                                position += delta;
                                                    notifyListeners();
                                                      }
                                                      }
                                                      