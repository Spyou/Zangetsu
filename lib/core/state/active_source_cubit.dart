import 'package:flutter_bloc/flutter_bloc.dart';

/// Holds the id of the currently-active content source (e.g. 'allanime',
/// 'netmirror_pv'). Replaces the old activeSource ValueNotifier.
class ActiveSourceCubit extends Cubit<String> {
  ActiveSourceCubit([super.initial = 'allanime']);

  void setSource(String id) {
    if (id != state) emit(id);
  }
}
