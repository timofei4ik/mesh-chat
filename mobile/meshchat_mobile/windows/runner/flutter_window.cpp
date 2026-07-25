#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr UINT kTrayCallbackMessage = WM_APP + 1;
constexpr UINT kOpenMeshChatCommand = 40001;
constexpr UINT kExitMeshChatCommand = 40002;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  window_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "meshchat/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<
                 flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "show") {
          RestoreFromTray();
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  AddTrayIcon();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  window_channel_.reset();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    tray_icon_added_ = false;
    AddTrayIcon();
    return 0;
  }

  switch (message) {
    case WM_CLOSE:
      if (!exiting_) {
        ShowWindow(hwnd, SW_HIDE);
        return 0;
      }
      break;
    case kTrayCallbackMessage: {
      const UINT tray_event = LOWORD(lparam);
      if (tray_event == WM_LBUTTONUP || tray_event == WM_LBUTTONDBLCLK ||
          tray_event == NIN_SELECT || tray_event == NIN_KEYSELECT) {
        RestoreFromTray();
        return 0;
      }
      if (tray_event == WM_RBUTTONUP || tray_event == WM_CONTEXTMENU) {
        ShowTrayMenu();
        return 0;
      }
      break;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::AddTrayIcon() {
  if (tray_icon_added_ || GetHandle() == nullptr) {
    return;
  }

  tray_icon_data_ = {};
  tray_icon_data_.cbSize = sizeof(tray_icon_data_);
  tray_icon_data_.hWnd = GetHandle();
  tray_icon_data_.uID = 1;
  tray_icon_data_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  tray_icon_data_.uCallbackMessage = kTrayCallbackMessage;
  tray_icon_data_.hIcon = static_cast<HICON>(
      LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON),
                 IMAGE_ICON, 0, 0, LR_DEFAULTSIZE | LR_SHARED));
  wcscpy_s(tray_icon_data_.szTip, L"MeshChat");

  tray_icon_added_ =
      Shell_NotifyIconW(NIM_ADD, &tray_icon_data_) == TRUE;
  if (tray_icon_added_) {
    tray_icon_data_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &tray_icon_data_);
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_) {
    return;
  }
  Shell_NotifyIconW(NIM_DELETE, &tray_icon_data_);
  tray_icon_added_ = false;
}

void FlutterWindow::RestoreFromTray() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }

  ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(hwnd);
}

void FlutterWindow::ShowTrayMenu() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }

  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }

  AppendMenuW(menu, MF_STRING, kOpenMeshChatCommand, L"Open MeshChat");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kExitMeshChatCommand, L"Exit");

  POINT cursor{};
  GetCursorPos(&cursor);
  SetForegroundWindow(hwnd);
  const UINT command =
      TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
                     cursor.x, cursor.y, 0, hwnd, nullptr);
  DestroyMenu(menu);

  if (command == kOpenMeshChatCommand) {
    RestoreFromTray();
  } else if (command == kExitMeshChatCommand) {
    exiting_ = true;
    RemoveTrayIcon();
    DestroyWindow(hwnd);
  }
}
