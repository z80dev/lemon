import { useEffect, useState } from 'react';
import { useApp } from '../../app';
import { useQuery, ErrorNotice, Loading } from '../../ui';

export function AccountAvatar({ attachmentId }: { attachmentId: string | null }) {
  const { client } = useApp();
  const image = useQuery(`settings:avatar:${attachmentId ?? 'none'}`, async () => {
    if (!attachmentId) return null;
    const download = await client.download(attachmentId);
    const bytes = await client.downloadBytes(download);
    return new Blob([new Uint8Array(bytes)], { type: download.mime });
  });
  const [url, setUrl] = useState<string>();
  useEffect(() => {
    if (!image.data) { setUrl(undefined); return; }
    const next = URL.createObjectURL(image.data); setUrl(next);
    return () => URL.revokeObjectURL(next);
  }, [image.data]);
  return <div className="stack"><ErrorNotice error={image.error} />{image.loading && attachmentId && <Loading />}{url ? <img className="settings-account-avatar" alt="Account avatar preview" src={url} /> : !attachmentId ? <span className="avatar settings-account-avatar" aria-label="No account avatar">◌</span> : null}</div>;
}
