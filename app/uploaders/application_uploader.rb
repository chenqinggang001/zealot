# frozen_string_literal: true

class ApplicationUploader < CarrierWave::Uploader::Base
  storage :file
  after :remove, :delete_empty_upstream_dirs

  def base_store_dir
    return Zealot::Storage::Manager.object_key('uploads') if Zealot::Storage::Manager.cloud_enabled?

    'uploads'
  end

  def size
    @size = file&.size
  end

  def checksum
    chunk = model.send(mounted_as)
    @checksum ||= Digest::MD5.hexdigest(chunk.read.to_s)
  end

  # Yield a real local path to `block`. For cloud-backed storage, streams the
  # object into a Tempfile; for :file storage, yields `file.path` directly.
  def with_local_path
    f = file
    return yield f.path if self.class.storage == CarrierWave::Storage::File

    ext = ::File.extname(f.filename.to_s)
    Tempfile.create(['zealot-', ext]) do |tmp|
      tmp.close
      Zealot::Storage::Manager.s3_client.get_object(
        bucket: Zealot::Storage::Manager.config[:bucket],
        key: f.path,
        response_target: tmp.path
      )
      yield tmp.path
    end
  end

  protected

  # Copy from https://github.com/carrierwaveuploader/carrierwave/wiki/how-to:-make-a-fast-lookup-able-storage-directory-structure
  def delete_empty_upstream_dirs
    path = ::File.expand_path(store_dir, root)
    Dir.delete(path) # fails if path not empty dir

    path = ::File.expand_path(base_store_dir, root)
    Dir.delete(path) # fails if path not empty dir
  rescue SystemCallError
    true # nothing, the dir is not empty
  end
end
