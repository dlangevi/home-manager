# Image generation on suspense, as a second inference service beside ollama.
#
# Why stable-diffusion.cpp and not ComfyUI or A1111: neither is in nixpkgs, so
# either would mean a third-party flake and a Python environment to keep
# working. sd-cpp is GGML/C++ with CUDA and GGUF weights -- the same shape as
# the ollama setup next door -- and is packaged here already.
#
# The hard constraint is the card, not the code. This is an 8G RTX 2070 SUPER
# and hosts/suspense.nix deliberately sizes qwen3.5's context so the LLM is
# fully resident, which is ~6.4G of it. Nothing meaningful fits beside that, so
# the two services take turns: the phone client POSTs keep_alive 0 to ollama
# before asking for an image, and ollama reloads on the next message. See
# Ollama.unload and ChatActivity.generate in ~/auto/android/chat.
{ config, pkgs, lib, ... }:

let
  port = 1234;

  # Same reasoning as services.ollama.package in hosts/suspense.nix: this is
  # unfree CUDA, so cache.nixos.org never carries it and it compiles locally.
  # The default builds every architecture nixpkgs knows about; 7.5 is the 2070
  # SUPER and is the only one this machine can execute. Change it with the GPU
  # or the binary dies with "no kernel image is available".
  sdPkgs = import pkgs.path {
    inherit (pkgs.stdenv.hostPlatform) system;
    config = pkgs.config // {
      cudaSupport = true;
      cudaCapabilities = [ "7.5" ];
      cudaForwardCompat = false;
    };
  };

  sd = sdPkgs.stable-diffusion-cpp;

  # Flux.1-schnell, quantized. Replaced SDXL-Turbo, which was chosen when the
  # client asked for 512x512 single-step images and was visibly the limit:
  # output was small, textures came out stamped, and text was never legible.
  #
  # Measured side by side at 1024x1024 on this card:
  #
  #   SDXL-Turbo q8_0   8 steps   10.7s
  #   Flux.1-schnell    4 steps   28.3s
  #
  # Three times the wait for a generational jump in composition and prompt
  # adherence, and the difference between unreadable glyphs and a legible
  # shop sign. Apache 2.0, unlike SDXL-Turbo's non-commercial licence.
  #
  # Flux is a DiT with separate text encoders rather than a single
  # checkpoint, so it is four files rather than one and there is nothing to
  # convert -- the GGUFs ship quantized.
  #
  # Q4_K_S over Q8_0 for the diffusion model is a RAM decision, not a VRAM
  # one: see the note on --offload-to-cpu below. Q8_0 is 12.7G against this
  # one's 6.8G, and the weights sit in host RAM permanently.
  flux = pkgs.fetchurl {
    url = "https://huggingface.co/city96/FLUX.1-schnell-gguf/resolve/main/flux1-schnell-Q4_K_S.gguf";
    hash = "sha256-T9Fkd7OlKW0M9yLEuSqf1/MNCax0lYJuRGXY3pyf2XM=";
  };

  # The text encoder, and the reason Flux follows a prompt as well as it
  # does. Quantized harder than the diffusion model would be a false economy
  # -- this is what reads the sentence.
  t5xxl = pkgs.fetchurl {
    url = "https://huggingface.co/city96/t5-v1_1-xxl-encoder-gguf/resolve/main/t5-v1_1-xxl-encoder-Q8_0.gguf";
    hash = "sha256-nsYPYChTS3/lr0Ofy1NddaaFkqnKP83rF174nj7pmCU=";
  };

  clipL = pkgs.fetchurl {
    url = "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors";
    hash = "sha256-ZgxvWxq66dxJisLSHhNH0qvbDPbAwMhXbNeWSR2abN0=";
  };

  # Flux's autoencoder. Fetched from the Comfy-Org mirror rather than
  # black-forest-labs/FLUX.1-schnell, whose copy sits behind a gated repo and
  # answers an unauthenticated fetch with 401. Byte-identical: 335304388.
  vae = pkgs.fetchurl {
    url = "https://huggingface.co/Comfy-Org/Lumina_Image_2.0_Repackaged/resolve/main/split_files/vae/ae.safetensors";
    hash = "sha256-r8jignLNFds5GbrNtpGM6cHtIulssSxNXtD7qCNSnjg=";
  };
in
{
  systemd.services.sd-server = {
    description = "stable-diffusion.cpp server (SDXL-Turbo)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "simple";

      # Same posture as services.ollama: no persistent identity, no home
      # directory full of half-downloaded weights. Everything it needs is a
      # store path, so the state directory is only scratch.
      DynamicUser = true;
      StateDirectory = "stable-diffusion";

      ExecStart = lib.concatStringsSep " " [
        "${sd}/bin/sd-server"
        # The default binds loopback, which the phone cannot reach. Exposure is
        # controlled by the firewall rules in hosts/suspense.nix, not by
        # binding narrowly -- the tailnet address is not known at eval time.
        "--listen-ip 0.0.0.0"
        "--listen-port ${toString port}"
        "--diffusion-model ${flux}"
        "--t5xxl ${t5xxl}"
        "--clip_l ${clipL}"
        "--vae ${vae}"
        # Flash attention in the diffusion model, for the same reason
        # OLLAMA_FLASH_ATTENTION is set next door: it is free throughput.
        "--diffusion-fa"

        # Keep the weights in host RAM and stage them into VRAM per request.
        # For Flux this is not a tuning choice -- it is the only way the model
        # runs here at all. Measured without it: sd-server dies at startup
        # trying to allocate the 6469 MiB of diffusion params against an 8G
        # card with ~1.2G already held by the desktop.
        #
        #   cudaMalloc failed: out of memory
        #   flux alloc params backend buffer failed, num_tensors = 776
        #
        # The consequence worth knowing: **nothing can be preloaded**. The
        # weights live in RAM permanently and are staged in per generation,
        # so there is no warm cache to build and no first-image penalty to
        # amortise. Measured back to back: 27.99s, 28.18s, 28.83s. A client
        # that offered a "warm up the GPU" button would be lying.
        #
        # (This differed under SDXL-Turbo, whose 4.0G did fit resident --
        # 0.65s resident against 1.26s offloaded. That option left with the
        # model.)
        #
        # The cost is RAM, not VRAM: 11.7G resident, permanently, of which
        # 6.5G is the diffusion model and 5.1G the T5 encoder. On a 31G box
        # that also runs a 6.4G LLM, that is the real budget constraint here
        # and the reason the diffusion model is Q4_K_S rather than Q8_0.
        "--offload-to-cpu"

        # Decode the VAE in tiles. This is what makes 1024x1024 possible at
        # all, and it is not a memory *optimisation* here -- it is the
        # difference between working and not. Measured untiled, with the
        # diffusion model succeeding and only the decode failing:
        #
        #   512x512     ok
        #   768x768     ok
        #   1024x1024   tries to allocate 7.68G for the VAE compute buffer
        #   1280x1280   tries to allocate 12.00G
        #
        # against an 8G card. Note where that lands you: the model samples
        # fine and then throws the latent away, so the symptom is an HTTP 500
        # with "vae decode compute failed" rather than anything naming size.
        #
        # It costs a flat ~5.1s per image at 1024 on top of ~0.70s/step.
        # Steep next to a 1-step model, which is why the client no longer uses
        # one -- see the step count in Sd.java.
        "--vae-tiling"

        # Budget for graph-cut segmented execution. Needed because the
        # staged-in diffusion model does not fit whole: without it the
        # generation fails per request with the same cudaMalloc error as
        # above, though unlike the startup case the server survives and
        # recovers.
        #
        # The value barely matters -- 28.5s at 4.0, 29.5s at 6.0, 30.2s at
        # 6.5, which is run-to-run noise. 6.0 leaves headroom under the 8G
        # card without being so tight that a slightly busier desktop breaks
        # it.
        "--max-vram 6.0"
      ];

      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
