// listener.cpp -- reference eavesdropper for Windows, such as cryostep.
//
// The behavior of eavesdrop.sh and sweep.sh in one program. It joins the
// multicast group and acts on each announcement, and in fetching mode it also
// lists the data computer every 30 seconds and fetches any image it is missing.
//
//     listener LOCAL                 notification only; writes nothing
//     listener LOCAL DATA DEST       notification and image
//
// LOCAL   this machine's address on the instrument LAN, such as 10.1.1.5. The
//         join is made on that interface. It is required: on a machine with
//         several adapters, including any VPN adapter, a join left to the
//         default can succeed and receive nothing.
// DATA    the data computer serving images, such as http://concordia1:8080.
//         The sweep lists it. It is the one address an eavesdropper cannot
//         learn from a datagram; change it by hand when the active machine
//         changes. Notified fetches use the URL in the datagram and follow a
//         failover on their own.
// DEST    the directory images are written under, reproducing the announced
//         path: DEST\20260828\img_0001.fits.
//
// The sweep is not optional when fetching. It covers dropped datagrams, time
// spent stopped, and every image delivered by a fallback path, none of which
// announce.
//
// Windows Firewall blocks inbound UDP by default, and the failure is silent.
// Allow the port once, from an administrator prompt:
//
//     netsh advfirewall firewall add rule name="Cryoscope notifications"
//         dir=in action=allow protocol=UDP localport=5555
//
// Build with Visual C++:
//
//     cl /EHsc listener.cpp
//
// or with mingw-w64:
//
//     x86_64-w64-mingw32-g++ -O2 -static -o listener.exe listener.cpp -lws2_32 -lwininet
//
// One line per event on standard output:
//
//     notified NAME   an exposure finished on the acquisition computer
//     fetched NAME    an announced image is now in DEST
//     swept NAME      an image the sweep found missing is now in DEST
//     rejected NAME   an announced name or URL was refused and not used
//     failed NAME     a fetch failed; the next sweep tries again
//     unreachable DATA   the sweep cannot list DATA, perhaps after a failover;
//                        said once, and "reachable DATA" when it can again

#define _WIN32_WINNT 0x0601
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <wininet.h>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
#include <system_error>
#include <thread>
#include <vector>

#pragma comment( lib, "ws2_32.lib" )
#pragma comment( lib, "wininet.lib" )

namespace Listener {

  // The wire contract: MCAST_GROUP and MCAST_PORT in site.conf.
  const std::string MCAST_GROUP = "239.192.1.1";
  const unsigned short MCAST_PORT = 5555;
  const std::chrono::seconds SWEEP_PERIOD( 30 );

  std::string data_url;  // DATA, without a trailing slash
  std::wstring dest_dir; // DEST, without a trailing separator
  HINTERNET internet = nullptr;
  std::mutex say_mutex; // one event line at a time from either thread

  struct Entry {
      std::string name;
      std::string type;
  };


  /***** Listener::say ********************************************************/
  /**
   * @brief      writes one event line to standard output, with the local time
   * @param[in]  what  the event, such as "fetched"
   * @param[in]  name  the image, or DATA
   *
   */
  void say( const std::string &what, const std::string &name ) {
    SYSTEMTIME now;
    GetLocalTime( &now );

    std::ostringstream oss;
    oss << what << " " << name << " at " << std::setfill( '0' ) << std::setw( 2 ) << now.wHour << ":" << std::setw( 2 )
        << now.wMinute << ":" << std::setw( 2 ) << now.wSecond << "." << std::setw( 3 ) << now.wMilliseconds << "\n";

    std::lock_guard<std::mutex> lock( say_mutex );
    std::cout << oss.str() << std::flush;
  }
  /***** Listener::say ********************************************************/


  /***** Listener::widen ******************************************************/
  /**
   * @brief      converts UTF-8 to the wide string Windows file calls take
   * @param[in]  narrow  UTF-8 string
   * @return     wide string, empty if the conversion fails
   *
   */
  std::wstring widen( const std::string &narrow ) {
    int length = MultiByteToWideChar( CP_UTF8, 0, narrow.c_str(), -1, nullptr, 0 );
    if ( length <= 0 ) return std::wstring();
    std::vector<wchar_t> wide( length );
    MultiByteToWideChar( CP_UTF8, 0, narrow.c_str(), -1, wide.data(), length );
    return std::wstring( wide.data() );
  }
  /***** Listener::widen ******************************************************/


  /***** Listener::ends_with **************************************************/
  /**
   * @brief      is tail the end of str
   * @param[in]  str
   * @param[in]  tail
   * @return     true|false
   *
   */
  bool ends_with( const std::string &str, const std::string &tail ) {
    return str.size() >= tail.size() && str.compare( str.size() - tail.size(), tail.size(), tail ) == 0;
  }
  /***** Listener::ends_with **************************************************/


  /***** Listener::safe_name **************************************************/
  /**
   * @brief      may this image name be used as a path under DEST
   * @details    The name arrives over an unauthenticated datagram, or in a
   *             listing, and is used as a path. Absolute names and ".." are
   *             refused, as eavesdrop.sh does, and so are a backslash and a
   *             colon, which Windows would read as a separator or a drive.
   * @param[in]  name  image name relative to the image root
   * @return     true|false
   *
   */
  bool safe_name( const std::string &name ) {
    return !name.empty() && name[0] != '/' && name.find( ".." ) == std::string::npos && name.find( '\\' ) == std::string::npos &&
           name.find( ':' ) == std::string::npos;
  }
  /***** Listener::safe_name **************************************************/


  /***** Listener::local_path *************************************************/
  /**
   * @brief      where an image is written under DEST
   * @param[in]  name  image name relative to the image root
   * @return     DEST\name, with Windows separators
   *
   */
  std::wstring local_path( const std::string &name ) {
    std::string path = name;
    std::replace( path.begin(), path.end(), '/', '\\' );
    return dest_dir + L"\\" + widen( path );
  }
  /***** Listener::local_path *************************************************/


  /***** Listener::make_parents ***********************************************/
  /**
   * @brief      creates each directory between DEST and the file
   * @param[in]  path  file path under DEST
   *
   */
  void make_parents( const std::wstring &path ) {
    for ( size_t pos = dest_dir.size() + 1; pos < path.size(); pos++ ) {
      if ( path[pos] == L'\\' ) CreateDirectoryW( path.substr( 0, pos ).c_str(), nullptr );
    }
  }
  /***** Listener::make_parents ***********************************************/


  /***** Listener::http_get ***************************************************/
  /**
   * @brief      fetches a URL into a string or a file
   * @details    Never answered from the cache: a cached listing would hide
   *             every image that arrived since.
   * @param[in]  url
   * @param[out] body  appended to, if not nullptr
   * @param[in]  file  written to, if body is nullptr
   * @return     true on status 200 with the whole body, else false
   *
   */
  bool http_get( const std::string &url, std::string* body, HANDLE file ) {
    HINTERNET request = InternetOpenUrlA(
        internet, url.c_str(), nullptr, 0,
        INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_CACHE_WRITE | INTERNET_FLAG_PRAGMA_NOCACHE | INTERNET_FLAG_NO_UI, 0 );
    if ( !request ) return false;

    DWORD status = 0, content_length = 0, field_size = sizeof( status );
    bool ok = HttpQueryInfoA( request, HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER, &status, &field_size, nullptr ) &&
              status == 200;
    field_size = sizeof( content_length );
    bool sized = HttpQueryInfoA( request, HTTP_QUERY_CONTENT_LENGTH | HTTP_QUERY_FLAG_NUMBER, &content_length, &field_size,
                                 nullptr ) != FALSE;

    std::vector<char> buffer( 1 << 16 );
    unsigned long long received = 0;
    DWORD count;
    while ( ok ) {
      if ( !InternetReadFile( request, buffer.data(), static_cast<DWORD>( buffer.size() ), &count ) ) {
        ok = false;
        break;
      }
      if ( count == 0 ) break;
      received += count;
      if ( body ) {
        body->append( buffer.data(), count );
      }
      else {
        DWORD written;
        if ( !WriteFile( file, buffer.data(), count, &written, nullptr ) || written != count ) ok = false;
      }
    }
    InternetCloseHandle( request );

    // A connection closed early can end the read without an error.
    return ok && ( !sized || received == content_length );
  }
  /***** Listener::http_get ***************************************************/


  /***** Listener::fetch ******************************************************/
  /**
   * @brief      fetches an image into DEST
   * @details    The image goes by way of a .part file renamed into place, so
   *             a file under its final name is always complete. An image
   *             already there is left alone. Both threads can fetch the same
   *             image at once; each writes its own .part file, and the second
   *             rename fails on the first one's file.
   * @param[in]  name  image name relative to the image root
   * @param[in]  url   where to fetch it from
   * @param[in]  done  the event said on success, "fetched" or "swept"
   *
   */
  void fetch( const std::string &name, const std::string &url, const std::string &done ) {
    std::wstring out = local_path( name );
    if ( GetFileAttributesW( out.c_str() ) != INVALID_FILE_ATTRIBUTES ) return;
    make_parents( out );

    std::wstring part = out + L".part" + std::to_wstring( GetCurrentThreadId() );
    HANDLE file = CreateFileW( part.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr );
    if ( file == INVALID_HANDLE_VALUE ) {
      say( "failed", name );
      return;
    }
    bool ok = http_get( url, nullptr, file );
    CloseHandle( file );

    if ( ok && MoveFileExW( part.c_str(), out.c_str(), MOVEFILE_WRITE_THROUGH ) ) {
      say( done, name );
      return;
    }
    DeleteFileW( part.c_str() );
    if ( !( ok && GetFileAttributesW( out.c_str() ) != INVALID_FILE_ATTRIBUTES ) ) say( "failed", name );
  }
  /***** Listener::fetch ******************************************************/


  /***** Listener::entries ****************************************************/
  /**
   * @brief      the name and type of each entry in an nginx JSON listing
   * @details    Read as sweep.sh reads it: "name":"x", "type":"y", with or
   *             without the space nginx puts after the comma.
   * @param[in]  listing  the JSON listing
   * @return     the entries, in listing order
   *
   */
  std::vector<Entry> entries( const std::string &listing ) {
    const std::string name_key = "\"name\":\"", type_key = "\"type\":\"";
    std::vector<Entry> found;
    size_t pos = 0;
    while ( ( pos = listing.find( name_key, pos ) ) != std::string::npos ) {
      pos += name_key.size();
      size_t name_end = listing.find( '"', pos );
      if ( name_end == std::string::npos ) break;
      size_t next = name_end + 1;
      if ( next < listing.size() && listing[next] == ',' ) next++;
      while ( next < listing.size() && listing[next] == ' ' )
        next++;
      if ( listing.compare( next, type_key.size(), type_key ) != 0 ) {
        pos = name_end;
        continue;
      }
      next += type_key.size();
      size_t type_end = listing.find( '"', next );
      if ( type_end == std::string::npos ) break;
      found.push_back( { listing.substr( pos, name_end - pos ), listing.substr( next, type_end - next ) } );
      pos = type_end;
    }
    return found;
  }
  /***** Listener::entries ****************************************************/


  /***** Listener::sweep_one **************************************************/
  /**
   * @brief      fetches one listed file, if it is an image and not yet in DEST
   * @param[in]  name  file name relative to the image root
   *
   */
  void sweep_one( const std::string &name ) {
    if ( ends_with( name, ".fits" ) && safe_name( name ) ) fetch( name, data_url + "/" + name, "swept" );
  }
  /***** Listener::sweep_one **************************************************/


  /***** Listener::sweep ******************************************************/
  /**
   * @brief      lists DATA every SWEEP_PERIOD and fetches what is missing
   * @details    The image root holds one level of dated directories, so the
   *             listing is taken in two steps: the directories, then the
   *             files in each. The first pass runs at start, which is the
   *             catch-up after any time stopped. Runs forever.
   *
   */
  void sweep() {
    bool reached = true;
    while ( true ) {
      std::string root;
      bool ok = http_get( data_url + "/", &root, nullptr );
      if ( ok != reached ) say( ok ? "reachable" : "unreachable", data_url );
      reached = ok;
      if ( ok ) {
        for ( const Entry &top : entries( root ) ) {
          if ( top.name.empty() || top.name[0] == '.' ) continue;
          if ( top.type == "directory" ) {
            std::string listing;
            if ( !http_get( data_url + "/" + top.name + "/", &listing, nullptr ) ) continue;
            for ( const Entry &file : entries( listing ) ) {
              if ( file.type == "file" ) sweep_one( top.name + "/" + file.name );
            }
          }
          else if ( top.type == "file" ) {
            sweep_one( top.name );
          }
        }
      }
      std::this_thread::sleep_for( SWEEP_PERIOD );
    }
  }
  /***** Listener::sweep ******************************************************/

} // namespace Listener


/***** main *******************************************************************/
int main( int argc, char** argv ) {
  if ( argc != 2 && argc != 4 ) {
    std::cerr << "usage: listener LOCAL [DATA DEST]\n"
              << "  LOCAL  this machine's instrument LAN address\n"
              << "  DATA   such as http://concordia1:8080\n"
              << "  DEST   the directory images are written under\n";
    return 2;
  }
  bool fetching = ( argc == 4 );
  std::string local_addr = argv[1];

  struct in_addr local;
  if ( inet_pton( AF_INET, local_addr.c_str(), &local ) != 1 ) {
    std::cerr << "listener: " << local_addr << " is not an IPv4 address\n";
    return 2;
  }

  WSADATA wsa;
  if ( WSAStartup( MAKEWORD( 2, 2 ), &wsa ) != 0 ) {
    std::cerr << "listener: WSAStartup failed\n";
    return 1;
  }

  SOCKET sock = socket( AF_INET, SOCK_DGRAM, IPPROTO_UDP );
  if ( sock == INVALID_SOCKET ) {
    std::cerr << "listener: socket failed, error " << WSAGetLastError() << "\n";
    return 1;
  }
  BOOL yes = TRUE;
  setsockopt( sock, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>( &yes ), sizeof( yes ) );
  // Datagrams wait here while an image is fetched.
  int rcvbuf = 1 << 20;
  setsockopt( sock, SOL_SOCKET, SO_RCVBUF, reinterpret_cast<const char*>( &rcvbuf ), sizeof( rcvbuf ) );

  struct sockaddr_in addr;
  memset( &addr, 0, sizeof( addr ) );
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl( INADDR_ANY );
  addr.sin_port = htons( Listener::MCAST_PORT );
  if ( bind( sock, reinterpret_cast<struct sockaddr*>( &addr ), sizeof( addr ) ) != 0 ) {
    std::cerr << "listener: cannot bind UDP port " << Listener::MCAST_PORT << ", error " << WSAGetLastError() << "\n";
    return 1;
  }

  struct ip_mreq mreq;
  memset( &mreq, 0, sizeof( mreq ) );
  inet_pton( AF_INET, Listener::MCAST_GROUP.c_str(), &mreq.imr_multiaddr );
  mreq.imr_interface = local;
  if ( setsockopt( sock, IPPROTO_IP, IP_ADD_MEMBERSHIP, reinterpret_cast<const char*>( &mreq ), sizeof( mreq ) ) != 0 ) {
    std::cerr << "listener: cannot join " << Listener::MCAST_GROUP << " on " << local_addr << ", error " << WSAGetLastError()
              << ". Is " << local_addr << " an address of this machine?\n";
    return 1;
  }

  if ( fetching ) {
    Listener::data_url = argv[2];
    while ( Listener::ends_with( Listener::data_url, "/" ) )
      Listener::data_url.pop_back();
    Listener::dest_dir = Listener::widen( argv[3] );
    while ( !Listener::dest_dir.empty() && ( Listener::dest_dir.back() == L'\\' || Listener::dest_dir.back() == L'/' ) ) {
      Listener::dest_dir.pop_back();
    }
    CreateDirectoryW( Listener::dest_dir.c_str(), nullptr );
    DWORD attributes = GetFileAttributesW( Listener::dest_dir.c_str() );
    if ( attributes == INVALID_FILE_ATTRIBUTES || !( attributes & FILE_ATTRIBUTE_DIRECTORY ) ) {
      std::cerr << "listener: cannot use " << argv[3] << " as the destination\n";
      return 1;
    }

    // Direct, so a proxy configured for the internet is never asked for a
    // machine on the instrument LAN.
    Listener::internet = InternetOpenA( "cryoscope-listener", INTERNET_OPEN_TYPE_DIRECT, nullptr, nullptr, 0 );
    if ( !Listener::internet ) {
      std::cerr << "listener: InternetOpen failed, error " << GetLastError() << "\n";
      return 1;
    }
    DWORD connect_ms = 5000, receive_ms = 300000;
    InternetSetOptionA( Listener::internet, INTERNET_OPTION_CONNECT_TIMEOUT, &connect_ms, sizeof( connect_ms ) );
    InternetSetOptionA( Listener::internet, INTERNET_OPTION_RECEIVE_TIMEOUT, &receive_ms, sizeof( receive_ms ) );
  }

  std::cout << "listening on " << Listener::MCAST_GROUP << ":" << Listener::MCAST_PORT << " via " << local_addr
            << ( fetching ? ", fetching" : ", notification only" ) << "\n"
            << std::flush;

  if ( fetching ) {
    try {
      std::thread( Listener::sweep ).detach();
    }
    catch ( const std::system_error &e ) {
      std::cerr << "listener: cannot start the sweep: " << e.what() << "\n";
      return 1;
    }
  }

  std::vector<char> datagram( 2048 );
  while ( true ) {
    int received = recv( sock, datagram.data(), static_cast<int>( datagram.size() ), 0 );
    if ( received <= 0 ) continue;

    std::istringstream message( std::string( datagram.data(), received ) );
    std::string tag, name, url;
    if ( !( message >> tag >> name ) ) continue;
    bool has_url = static_cast<bool>( message >> url );

    if ( tag == "IMAGE_COMPLETE" ) {
      // The exposure finished. Nothing is fetchable yet.
      Listener::say( "notified", name );
      continue;
    }
    // Anything else that is not handled here is ignored rather than
    // treated as an error, so the protocol can be extended.
    if ( tag != "IMAGE_AVAILABLE" || !fetching || !has_url ) continue;

    // The URL comes from the datagram and is never built here. This is
    // what makes notified fetches follow a failover.
    if ( !Listener::safe_name( name ) || url.compare( 0, 7, "http://" ) != 0 ) {
      Listener::say( "rejected", name );
      continue;
    }
    Listener::fetch( name, url, "fetched" );
  }
}
/***** main *******************************************************************/
