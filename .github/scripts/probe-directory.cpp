#include <windows.h>
#include <filesystem>
#include <iostream>
#include <vector>

int main()
{
    const auto root = std::filesystem::temp_directory_path() / L"wsl-directory-sharing-probe";
    std::filesystem::create_directory(root);
    int failures = 0;
    for (DWORD access : {DWORD(FILE_READ_ATTRIBUTES), DWORD(DELETE | FILE_READ_ATTRIBUTES)})
    {
        for (DWORD sharing : {DWORD(FILE_SHARE_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE)})
        {
            const auto dir = root / (std::to_wstring(access) + L"-" + std::to_wstring(sharing));
            std::filesystem::create_directory(dir);
            const auto source = root / L"source.vhdx";
            HANDLE file = CreateFileW(source.c_str(), DELETE | FILE_READ_ATTRIBUTES, FILE_SHARE_READ, nullptr, CREATE_ALWAYS, 0, nullptr);
            HANDLE directory = CreateFileW(dir.c_str(), access, sharing, nullptr, OPEN_EXISTING,
                                           FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
            if (file == INVALID_HANDLE_VALUE || directory == INVALID_HANDLE_VALUE) return 2;
            const auto target = (dir / L"disk.vhdx").wstring();
            std::vector<BYTE> buffer(sizeof(FILE_RENAME_INFO) + target.size() * sizeof(wchar_t));
            auto info = reinterpret_cast<FILE_RENAME_INFO*>(buffer.data());
            info->FileNameLength = static_cast<DWORD>(target.size() * sizeof(wchar_t));
            memcpy(info->FileName, target.data(), info->FileNameLength);
            const bool renamed = SetFileInformationByHandle(file, FileRenameInfo, info, static_cast<DWORD>(buffer.size()));
            const auto error = renamed ? ERROR_SUCCESS : GetLastError();
            std::cout << "access=" << access << " sharing=" << sharing << " renamed=" << renamed << " error=" << error << std::endl;
            if (access == FILE_READ_ATTRIBUTES && sharing == (FILE_SHARE_READ | FILE_SHARE_WRITE) && !renamed) ++failures;
            CloseHandle(file);
            CloseHandle(directory);
            std::filesystem::remove_all(dir);
            std::filesystem::remove(source);
        }
    }
    std::filesystem::remove(root);
    return failures;
}
