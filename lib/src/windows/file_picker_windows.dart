import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/utils.dart';
import 'package:file_picker/src/windows/file_picker_windows_ffi_types.dart';
import 'package:path/path.dart';

FilePicker filePickerWithFFI() => FilePickerWindows();

class FilePickerWindows extends FilePicker {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
  }) async {
    final comdlg32 = DynamicLibrary.open('comdlg32.dll');

    final getOpenFileNameW =
        comdlg32.lookupFunction<GetOpenFileNameW, GetOpenFileNameWDart>(
            'GetOpenFileNameW');

    final Pointer<OPENFILENAMEW> openFileName = calloc<OPENFILENAMEW>();
    openFileName.ref.lStructSize = sizeOf<OPENFILENAMEW>();
    openFileName.ref.lpstrTitle =
        (dialogTitle ?? defaultDialogTitle).toNativeUtf16();
    openFileName.ref.lpstrFile = calloc.allocate<Utf16>(maxPath);
    openFileName.ref.lpstrFilter =
        fileTypeToFileFilter(type, allowedExtensions).toNativeUtf16();
    openFileName.ref.nMaxFile = maxPath;
    openFileName.ref.lpstrInitialDir = ''.toNativeUtf16();
    openFileName.ref.flags = ofnExplorer | ofnFileMustExist | ofnHideReadOnly;
    if (allowMultiple) {
      openFileName.ref.flags |= ofnAllowMultiSelect;
    }

    final result = getOpenFileNameW(openFileName);
    if (result == 1) {
      final filePaths =
          _extractSelectedFilesFromOpenFileNameW(openFileName.ref);
      final platformFiles =
          await filePathsToPlatformFiles(filePaths, withReadStream, withData);

      return FilePickerResult(platformFiles);
    }
    return null;
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
  }) {
    final pathIdPointer = _pickDirectory(dialogTitle ?? defaultDialogTitle);
    if (pathIdPointer == null) {
      return Future.value(null);
    }
    return Future.value(
      _getPathFromItemIdentifierList(pathIdPointer),
    );
  }

  String fileTypeToFileFilter(FileType type, List<String>? allowedExtensions) {
    switch (type) {
      case FileType.any:
        return '*.*\x00\x00';
      case FileType.audio:
        return 'Audios (*.mp3)\x00*.mp3\x00All Files (*.*)\x00*.*\x00\x00';
      case FileType.custom:
        return 'Files (*.${allowedExtensions!.join(',*.')})\x00\x00';
      case FileType.image:
        return 'Images (*.jpeg,*.png,*.gif)\x00*.jpg;*.jpeg;*.png;*.gif\x00All Files (*.*)\x00*.*\x00\x00';
      case FileType.media:
        return 'Videos (*.webm,*.wmv,*.mpeg,*.mkv,*.mp4,*.avi,*.mov,*.flv)\x00*.webm;*.wmv;*.mpeg;*.mkv;*mp4;*.avi;*.mov;*.flv\x00Images (*.jpeg,*.png,*.gif)\x00*.jpg;*.jpeg;*.png;*.gif\x00All Files (*.*)\x00*.*\x00\x00';
      case FileType.video:
        return 'Videos (*.webm,*.wmv,*.mpeg,*.mkv,*.mp4,*.avi,*.mov,*.flv)\x00*.webm;*.wmv;*.mpeg;*.mkv;*mp4;*.avi;*.mov;*.flv\x00All Files (*.*)\x00*.*\x00\x00';
      default:
        throw Exception('unknown file type');
    }
  }

  /// Uses the Win32 API to display a dialog box that enables the user to select a folder.
  ///
  /// Returns a PIDL that specifies the location of the selected folder relative to the root of the
  /// namespace. Returns null, if the user clicked on the "Cancel" button in the dialog box.
  Pointer? _pickDirectory(String dialogTitle) {
    final shell32 = DynamicLibrary.open('shell32.dll');

    final shBrowseForFolderW =
        shell32.lookupFunction<SHBrowseForFolderW, SHBrowseForFolderW>(
            'SHBrowseForFolderW');

    final Pointer<BROWSEINFOA> browseInfo = calloc<BROWSEINFOA>();
    browseInfo.ref.hwndOwner = nullptr;
    browseInfo.ref.pidlRoot = nullptr;
    browseInfo.ref.pszDisplayName = calloc.allocate<Utf16>(maxPath);
    browseInfo.ref.lpszTitle = dialogTitle.toNativeUtf16();
    browseInfo.ref.ulFlags =
        bifEditBox | bifNewDialogStyle | bifReturnOnlyFsDirs;

    final Pointer<NativeType> itemIdentifierList =
        shBrowseForFolderW(browseInfo);

    calloc.free(browseInfo.ref.pszDisplayName);
    calloc.free(browseInfo.ref.lpszTitle);
    calloc.free(browseInfo);

    if (itemIdentifierList == nullptr) {
      return null;
    }
    return itemIdentifierList;
  }

  /// Uses the Win32 API to convert an item identifier list to a file system path.
  ///
  /// [lpItem] must contain the address of an item identifier list that specifies a
  /// file or directory location relative to the root of the namespace (the desktop).
  /// Returns the file system path as a [String]. Throws an exception, if the
  /// conversion wasn't successful.
  String _getPathFromItemIdentifierList(Pointer lpItem) {
    final shell32 = DynamicLibrary.open('shell32.dll');

    final shGetPathFromIDListW =
        shell32.lookupFunction<SHGetPathFromIDListW, SHGetPathFromIDListWDart>(
            'SHGetPathFromIDListW');

    final Pointer<Utf16> pszPath = calloc.allocate<Utf16>(maxPath);

    final int result = shGetPathFromIDListW(lpItem, pszPath);
    if (result == 0x00000000) {
      throw Exception(
          'Failed to convert item identifier list to a file system path.');
    }

    calloc.free(pszPath);

    return pszPath.toDartString();
  }

  /// Extracts the list of selected files from the Win32 API struct [OPENFILENAMEW].
  ///
  /// After the user has closed the file picker dialog, Win32 API sets the property
  /// [lpstrFile] of [OPENFILENAMEW] to the user's selection. This property contains
  /// a string terminated by two [null] characters. If the user has selected only one
  /// file, then the returned string contains the absolute file path, e. g.
  /// `C:\Users\John\file1.jpg\x00\x00`. If the user has selected more than one file,
  /// then the returned string contains the directory of the selected files, followed
  /// by a [null] character, followed by the file names each separated by a [null]
  /// character, e.g. `C:\Users\John\x00file1.jpg\x00file2.jpg\x00file3.jpg\x00\x00`.
  List<String> _extractSelectedFilesFromOpenFileNameW(
    OPENFILENAMEW openFileNameW,
  ) {
    final List<String> filePaths = [];
    final buffer = StringBuffer();
    int i = 0;
    bool lastCharWasNull = false;

    while (true) {
      final char = openFileNameW.lpstrFile.cast<Uint16>().elementAt(i).value;
      if (char == 0) {
        if (lastCharWasNull) {
          break;
        } else {
          filePaths.add(buffer.toString());
          buffer.clear();
          lastCharWasNull = true;
        }
      } else {
        lastCharWasNull = false;
        buffer.writeCharCode(char);
      }
      i++;
    }

    if (filePaths.length > 1) {
      final String directoryPath = filePaths.removeAt(0);
      return filePaths
          .map<String>((filePath) => join(directoryPath, filePath))
          .toList();
    }

    return filePaths;
  }
}
