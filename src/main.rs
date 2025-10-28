use clap::{Parser, Subcommand};
use std::os::windows::io::AsRawHandle;
use std::{num::ParseIntError, path::Path, time::Duration};
use tokio::net::windows::named_pipe::NamedPipeClient;
use tokio::{
    io::{self as io, AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, BufStream},
    net::{TcpStream, windows::named_pipe::ClientOptions},
};
use windows_sys::Win32::Foundation::{
    ERROR_BROKEN_PIPE, ERROR_PIPE_BUSY, ERROR_PIPE_NOT_CONNECTED,
};
use windows_sys::Win32::Storage::FileSystem::{ReadFile, WriteFile};

const BUF_SIZE: usize = 64 * 1024;

#[derive(Clone, Debug, Subcommand)]
enum Mode {
    Gpg {
        #[arg(short, long)]
        socket: String,
    },
    Pipe {
        #[arg(long = "p")]
        poll: bool,

        #[arg(long = "s")]
        close_write: bool,

        #[arg(long = "ep")]
        close_on_eof: bool,

        #[arg(long = "ei")]
        close_on_stdin_eof: bool,

        #[arg(long)]
        name: String,
    },
}

#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Args {
    #[command(subcommand)]
    mode: Mode,
}

#[derive(thiserror::Error, Debug)]
enum Error {
    #[error("IO error: {0}")]
    IO(#[source] std::io::Error),

    #[error("Failed to parse int: {0}")]
    ParseInt(#[source] ParseIntError),

    #[error("Invalid number of bytes {0} expected 16 bytes")]
    InvalidNonce(usize),
}

#[tokio::main]
async fn main() -> Result<(), Error> {
    let args = Args::parse();

    match args.mode {
        Mode::Gpg { socket } => gpg_conn(socket).await,
        Mode::Pipe {
            poll,
            close_write,
            close_on_eof,
            close_on_stdin_eof,
            name,
        } => ssh_conn(poll, close_write, close_on_eof, close_on_stdin_eof, &name).await,
    }
}

async fn gpg_conn(socket_name: String) -> Result<(), Error> {
    let socket_file_path = Path::new(home::home_dir().unwrap().to_str().unwrap())
        .join("AppData")
        .join("Local")
        .join("gnupg")
        .join(socket_name);

    let socket_file = tokio::fs::File::open(socket_file_path)
        .await
        .map_err(Error::IO)?;
    let mut buf = BufReader::new(socket_file);
    let mut port_buf = String::new();
    let mut nonce_buf = [0; 16];

    buf.read_line(&mut port_buf).await.map_err(Error::IO)?;
    let n = buf.read(&mut nonce_buf).await.map_err(Error::IO)?;
    if n > 16 {
        return Err(Error::InvalidNonce(n));
    }

    let port: u16 = port_buf.trim().parse().map_err(Error::ParseInt)?;

    let mut stream = TcpStream::connect(format!("localhost:{}", port))
        .await
        .map_err(Error::IO)?;

    stream.write(&nonce_buf).await.map_err(Error::IO)?;

    let (mut stream_in, mut stream_out) = stream.split();
    let mut stdin = io::stdin();
    let mut stdout = io::stdout();

    let mut reader = async move || io::copy(&mut stdin, &mut stream_out).await;
    let mut writer = async move || io::copy(&mut stream_in, &mut stdout).await;

    tokio::select! {
        _ = reader() => {},
        _ = writer() => {},
    };

    Ok(())
}

async fn connect_pipe(poll: bool, pipe_name: &str) -> io::Result<NamedPipeClient> {
    loop {
        match ClientOptions::new().open(pipe_name) {
            Ok(client) => break Ok(client),
            Err(err) if err.raw_os_error() == Some(ERROR_PIPE_BUSY as i32) => {}
            Err(err) if err.kind() == io::ErrorKind::NotFound && poll => {}
            Err(err) => return Err(err),
        }

        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

async fn ssh_conn(
    poll: bool,
    close_write: bool,
    close_on_eof: bool,
    close_on_stdin_eof: bool,
    pipe_name: &str,
) -> Result<(), Error> {
    let client = connect_pipe(poll, pipe_name).await.map_err(Error::IO)?;
    let raw_handle = client.as_raw_handle();
    let client = BufStream::new(client);
    let (mut np_reader, mut np_writer) = io::split(client);

    let mut stdin_to_pipe = async || {
        let mut stdin = io::stdin();
        let mut buf = [0u8; BUF_SIZE];
        loop {
            match stdin.read(&mut buf).await.map_err(Error::IO)? {
                0 => {
                    if close_on_stdin_eof {
                        break;
                    }

                    if close_write {
                        write_zero_byte_message(raw_handle).map_err(Error::IO)?;
                    }

                    np_writer.shutdown().await.map_err(Error::IO)?;
                    break;
                }
                n => np_writer.write_all(&buf[..n]).await.map_err(Error::IO)?,
            }
        }

        Ok::<_, Error>(())
    };

    let mut pipe_to_stdout = async || {
        let mut stdout = io::stdout();
        let mut buf = [0u8; BUF_SIZE];
        loop {
            match np_reader.read(&mut buf).await {
                Ok(0) => {
                    if close_on_eof {
                        return Ok::<_, Error>(());
                    }

                    break;
                }
                Ok(n) => stdout.write_all(&buf[..n]).await.map_err(Error::IO)?,
                Err(e) => match e.raw_os_error().map(|x| x as u32) {
                    Some(ERROR_BROKEN_PIPE | ERROR_PIPE_NOT_CONNECTED) => return Ok(()),
                    _ => return Err(Error::IO(e)),
                },
            }
        }

        loop {
            match read_zero_probe(raw_handle) {
                Ok(()) => tokio::time::sleep(Duration::from_millis(50)).await,
                Err(e) if e.raw_os_error() == Some(ERROR_BROKEN_PIPE as i32) => {
                    return Ok(());
                }
                Err(e) => {
                    return Err(Error::IO(e));
                }
            }
        }
    };

    tokio::select! {
        res = stdin_to_pipe() => res?,
        res = pipe_to_stdout() => res?,
    }

    Ok(())
}

fn read_zero_probe(handle: std::os::windows::io::RawHandle) -> std::io::Result<()> {
    let mut read = 0u32;
    if unsafe {
        ReadFile(
            handle as *const _ as *mut std::ffi::c_void,
            std::ptr::null_mut(),
            0,
            &mut read,
            std::ptr::null_mut(),
        )
    } == 0
    {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn write_zero_byte_message(handle: std::os::windows::io::RawHandle) -> std::io::Result<()> {
    let mut written = 0u32;
    if unsafe {
        WriteFile(
            handle as *const _ as *mut std::ffi::c_void,
            std::ptr::null(),
            0,
            &mut written,
            std::ptr::null_mut(),
        )
    } == 0
    {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}
