use clap::{Parser, Subcommand};
use std::{num::ParseIntError, path::Path, time::Duration};
use tokio::{
    io::{self, AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, BufStream},
    net::{TcpStream, windows::named_pipe::ClientOptions},
};
use windows_sys::Win32::Foundation::ERROR_PIPE_BUSY;

#[derive(Clone, Debug, Subcommand)]
enum Mode {
    Gpg {
        #[arg(short, long)]
        socket: String,
    },
    Ssh {
        #[arg(short, long)]
        pipe: String,
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
async fn main() {
    let args = Args::parse();

    match args.mode {
        Mode::Gpg { socket } => {
            gpg_conn(socket).await.unwrap();
        }
        Mode::Ssh { pipe } => {
            ssh_conn(&pipe).await.unwrap();
        }
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

    let (r1, r2) = tokio::join!(reader(), writer());

    r1.unwrap();
    r2.unwrap();

    Ok(())
}

async fn ssh_conn(pipe: &str) -> Result<(), Error> {
    let client = loop {
        match ClientOptions::new().open(pipe) {
            Ok(client) => break client,
            Err(err) if err.raw_os_error() == Some(ERROR_PIPE_BUSY as i32) => {}
            Err(err) => return Err(Error::IO(err)),
        }

        tokio::time::sleep(Duration::from_millis(50)).await;
    };

    let client = BufStream::new(client);
    let (mut np_reader, mut np_writer) = io::split(client);
    let mut stdio_reader = io::stdin();
    let mut stdio_writer = io::stdout();

    let mut reader = async move || io::copy(&mut stdio_reader, &mut np_writer).await;
    let mut writer = async move || io::copy(&mut np_reader, &mut stdio_writer).await;

    tokio::select! {
        _ = reader() => {},
        _ = writer() => {},

    };

    Ok(())
}
