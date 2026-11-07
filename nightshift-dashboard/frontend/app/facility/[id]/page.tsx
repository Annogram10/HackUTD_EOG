import { Suspense } from "react";
import FacilityView from "@/components/FacilityView";

// useParams() needs a Suspense boundary with cacheComponents on.
export default function FacilityPage() {
  return (
    <Suspense fallback={<div className="h-96 animate-pulse rounded-2xl bg-zinc-900" />}>
      <FacilityView />
    </Suspense>
  );
}
