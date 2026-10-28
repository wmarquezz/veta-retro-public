"""Keep Azahar savestate archive roots portable across iOS container moves."""


def apply(source, replace):
    utility = source / 'src/common/file_util.cpp'
    replace(utility, '''    StringReplace(result, "%CITRA_USER_NAND%", GetUserPath(UserPath::NANDDir), is_saving);
    return result;''', '''    StringReplace(result, "%CITRA_USER_NAND%", GetUserPath(UserPath::NANDDir), is_saving);
    // Older VETA states serialized archive roots as absolute strings. iOS
    // can relocate the data container during an update or library migration.
    // Rebase only VETA's per-game Azahar subtree, never arbitrary host paths.
    if (!is_saving) {
        const std::string marker = "/CoreSaves/Azahar/";
        const auto offset = result.find(marker);
        const auto& current = GetUserPath(UserPath::UserDir);
        if (offset != std::string::npos && current.ends_with(marker)) {
            const auto suffix = result.substr(offset + marker.size());
            // No path traversal may escape the current per-game root.
            if (suffix != ".." && !suffix.starts_with("../") &&
                suffix.find("/../") == std::string::npos && !suffix.ends_with("/..")) {
                result = current + suffix;
            }
        }
    }
    return result;''')
    # Preserve the serialized type (std::string), so existing states remain
    # readable. Do not add a wrapper/version header to the Boost archive.
    members = {
        'savedata_archive.h': ['mount_point'],
        'archive_nand.h': ['mount_point', 'nand_directory'],
        'archive_source_sd_savedata.h': ['mount_point'],
        'archive_sdmc.h': ['mount_point', 'sdmc_directory'],
        'archive_sdmcwriteonly.h': ['sdmc_directory'],
        'archive_extsavedata.h': ['mount_point'],
        'archive_systemsavedata.h': ['base_path'],
    }
    for filename, names in members.items():
        path = source / 'src/core/file_sys' / filename
        if '#include "common/file_util.h"' not in path.read_text():
            replace(path, '#pragma once', '#pragma once\n#include "common/file_util.h"')
        for name in names:
            replace(path, f'        ar & {name};', f'''        if constexpr (Archive::is_saving::value) {{
            auto portable = FileUtil::SerializePath({name}, true);
            ar & portable;
        }} else {{
            ar & {name};
            {name} = FileUtil::SerializePath({name}, false);
        }}''')
    cecd = source / 'src/core/hle/service/cecd/cecd.cpp'
    replace(cecd, '        if (path_type == CecDataPathType::MboxProgramId) {',
            '        if (session_data->file && path_type == CecDataPathType::MboxProgramId) {')
    for buffer in ['write_buffer', 'read_buffer']:
        count = '            rb.Push<u32>(0);\n' if buffer == 'write_buffer' else ''
        anchor = f'''    default: // If not directory, then it is a file
        std::vector<u8> buffer({buffer}_size);'''
        replace(cecd, anchor, f'''    default: // If not directory, then it is a file
        if (!session_data->file) {{
            rb.Push(Result(ErrorDescription::NoData, ErrorModule::CEC, ErrorSummary::NotFound,
                           ErrorLevel::Status));
{count}            rb.PushMappedBuffer({buffer});
            return;
        }}
        std::vector<u8> buffer({buffer}_size);''')
    replace(cecd, '''        const u32 bytes_read = static_cast<u32>(
            session_data->file->Read(0, write_buffer_size, buffer.data()).Unwrap());''', '''        const auto read_result = session_data->file->Read(0, write_buffer_size, buffer.data());
        if (read_result.Failed()) {
            rb.Push(read_result.Code()); rb.Push<u32>(0); rb.PushMappedBuffer(write_buffer);
            return;
        }
        const u32 bytes_read = static_cast<u32>(read_result.Unwrap());''')
    replace(cecd, '''        [[maybe_unused]] const u32 bytes_written = static_cast<u32>(
            session_data->file->Write(0, buffer.size(), true, false, buffer.data()).Unwrap());''', '''        const auto write_result = session_data->file->Write(0, buffer.size(), true, false, buffer.data());
        if (write_result.Failed()) {
            rb.Push(write_result.Code()); rb.PushMappedBuffer(read_buffer);
            return;
        }''')
