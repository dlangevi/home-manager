# The read side of the JPC music pipeline, for the machine that holds the
# library (dance).
#
# This deliberately does NOT come from the cdrip flake in ~/auto/music-mgmt.
# That is a `path:` input which only resolves on the machine the repo lives
# on, so referencing it from dance's config fails to evaluate. Nothing here
# needs cdrip anyway -- it is stock beets plus a static config.
{ pkgs, config, ... }:

{
  home.packages = [ pkgs.beets ];

  # `cdrip sync-db`, running on suspense, writes this database. It is a
  # DERIVED COPY, overwritten in full on every sync: read from it, never edit
  # it here. The authoritative database lives on suspense.
  #
  # beets 2.x stores item paths relative to `directory`, which is what lets a
  # database built against suspense's staging tree resolve against the real
  # files here.
  xdg.configFile."beets/config.yaml".text = ''
    directory: /srv/media/jpc-music
    library: ${config.home.homeDirectory}/.local/share/cdrip/library.db

    paths:
      default: $albumartist/$album/$track $title
      singleton: $artist/Non-Album/$title
      comp: $albumartist/$album/$track $title
  '';
}
