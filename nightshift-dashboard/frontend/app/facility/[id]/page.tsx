import { PageSkeleton } from "@/components/Skeleton";
import { Suspense } from "react";
import FacilityView from "@/components/FacilityView";

// useParams() needs a Suspense boundary with cacheComponents on.
export default function FacilityPage() {
  return (
    <Suspense fallback={<PageSkeleton cards={3} />}>
      <FacilityView />
    </Suspense>
  );
}
